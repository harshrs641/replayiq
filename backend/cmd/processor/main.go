// Command processor is the Kafka consumer service.  It runs three concurrent
// workers:
//
//	storage-worker-raw    events.raw      → MinIO sessions bucket
//	storage-worker-masked events.masked   → MinIO sessions-masked bucket
//	ai-worker             session.analyze-requested → AI pipeline → Postgres
//
// There is no HTTP server; the processor is a pure background worker.
package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/harshrs641/replayiq/internal/ai"
	"github.com/harshrs641/replayiq/internal/ingest"
	"github.com/harshrs641/replayiq/internal/kafka"
	"github.com/harshrs641/replayiq/internal/masking"
	"github.com/harshrs641/replayiq/internal/models"
	"github.com/harshrs641/replayiq/internal/pipeline"
	"github.com/harshrs641/replayiq/internal/storage"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))

	writeDSN := getEnv("DATABASE_URL", "postgres://replayiq:replayiq_secret@localhost:5432/replayiq?sslmode=disable")
	readDSN := getEnv("DATABASE_READ_URL", writeDSN)
	kafkaBrokers := strings.Split(getEnv("KAFKA_BROKERS", "localhost:9092"), ",")
	bucket := getEnv("MINIO_BUCKET", "sessions")

	db, err := storage.NewPostgres(writeDSN, readDSN)
	if err != nil {
		slog.Error("postgres connect failed", "error", err)
		os.Exit(1)
	}

	minio, err := storage.NewMinIO(
		getEnv("MINIO_ENDPOINT", "localhost:9000"),
		getEnv("MINIO_ACCESS_KEY", "minioadmin"),
		getEnv("MINIO_SECRET_KEY", "minioadmin"),
		bucket,
		getEnv("MINIO_MASKED_BUCKET", bucket+"-masked"),
		getEnv("MINIO_SECURE", "false") == "true",
	)
	if err != nil {
		slog.Error("minio connect failed", "error", err)
		os.Exit(1)
	}

	aiEngine := ai.NewOllamaEngine(
		getEnv("OLLAMA_ENDPOINT", "http://localhost:11434"),
		getEnv("OLLAMA_MODEL", "llama3.1:8b"),
		getEnv("EMBEDDING_MODEL", "nomic-embed-text"),
	).WithModelTiering(
		getEnv("OLLAMA_SMALL_MODEL", ""),
		getEnv("OLLAMA_LARGE_MODEL", ""),
	)

	analyzer := pipeline.NewAnalyzer(db, minio, aiEngine, getEnvInt("ANALYSIS_CONCURRENCY", 0))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var wg sync.WaitGroup

	// Transformer — events.native → convert mobile recordings to rrweb, keep
	// the native copy, mask → events.raw / events.masked (package ingest).
	producer := kafka.NewProducer(kafkaBrokers)
	defer producer.Close()
	var extraMaskClasses []string
	if mc := getEnv("MASK_CLASSES", ""); mc != "" {
		extraMaskClasses = strings.Split(mc, ",")
	}
	transformer := &ingest.Processor{
		MinIO:        minio,
		Masking:      masking.DefaultConfig(extraMaskClasses),
		Tracker:      masking.NewTracker(),
		Publisher:    producer,
		PublicAPIURL: getEnv("PUBLIC_API_URL", "http://localhost:8080"),
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		slog.Info("transformer starting", "topic", kafka.TopicEventsNative)
		c := kafka.NewConsumer(kafkaBrokers, "transformer", kafka.TopicEventsNative)
		defer c.Close()
		c.Run(ctx, func(msg kafka.Message) error {
			var batch models.EventBatch
			if err := json.Unmarshal(msg.Value, &batch); err != nil {
				return err
			}
			return transformer.Process(ctx, batch)
		})
	}()

	// Storage Worker — raw events → MinIO raw bucket
	wg.Add(1)
	go func() {
		defer wg.Done()
		slog.Info("storage-worker-raw starting", "topic", kafka.TopicEventsRaw)
		c := kafka.NewConsumer(kafkaBrokers, "storage-worker-raw", kafka.TopicEventsRaw)
		defer c.Close()
		c.Run(ctx, func(msg kafka.Message) error {
			var batch models.EventBatch
			if err := json.Unmarshal(msg.Value, &batch); err != nil {
				return err
			}
			_, err := minio.StoreEvents(ctx, batch.SessionID, &batch)
			return err
		})
	}()

	// Storage Worker — masked events → MinIO masked bucket
	wg.Add(1)
	go func() {
		defer wg.Done()
		slog.Info("storage-worker-masked starting", "topic", kafka.TopicEventsMasked)
		c := kafka.NewConsumer(kafkaBrokers, "storage-worker-masked", kafka.TopicEventsMasked)
		defer c.Close()
		c.Run(ctx, func(msg kafka.Message) error {
			var batch models.EventBatch
			if err := json.Unmarshal(msg.Value, &batch); err != nil {
				return err
			}
			_, err := minio.StoreMaskedEvents(ctx, batch.SessionID, &batch)
			return err
		})
	}()

	// AI Worker — session.analyze-requested → AI pipeline
	wg.Add(1)
	go func() {
		defer wg.Done()
		slog.Info("ai-worker starting", "topic", kafka.TopicAnalyzeRequested)
		c := kafka.NewConsumer(kafkaBrokers, "ai-worker", kafka.TopicAnalyzeRequested)
		defer c.Close()
		c.Run(ctx, func(msg kafka.Message) error {
			var evt kafka.AnalyzeRequestedEvent
			if err := json.Unmarshal(msg.Value, &evt); err != nil {
				return err
			}
			if evt.DelayMs > 0 {
				delay := evt.DelayMs
				if delay > 10_000 {
					delay = 10_000 // cap at 10 s to limit consumer lag
				}
				slog.Info("ai-worker delaying for last-batch flush",
					"session_id", evt.SessionID, "delay_ms", delay)
				select {
				case <-ctx.Done():
					return ctx.Err()
				case <-time.After(time.Duration(delay) * time.Millisecond):
				}
			}
			return analyzer.Analyze(ctx, evt.SessionID)
		})
	}()

	// Retention — deletes expired sessions (stored events and rows) hourly.
	retention, err := pipeline.ParseRetention(getEnvInt("SESSION_RETENTION_DAYS", 0), getEnv("SESSION_RETENTION_DAYS_BY_PROJECT", ""))
	if err != nil {
		slog.Error("invalid retention config", "error", err)
		os.Exit(1)
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		pipeline.RunRetention(ctx, pipeline.StorageRetention{DB: db, MinIO: minio}, retention, time.Hour)
	}()

	slog.Info("processor ready — waiting for messages")
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	slog.Info("processor shutting down")
	cancel()
	wg.Wait()
	slog.Info("processor stopped")
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getEnvInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return fallback
}
