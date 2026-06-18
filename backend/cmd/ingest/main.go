// Command ingest is the Ingest API service: it receives session lifecycle
// events and raw event batches from the SDK, writes session metadata to
// Postgres synchronously, and publishes event payloads to Kafka for the
// processor service to persist and analyse.
//
// Listens on :8081 by default (INGEST_PORT to override).
// Sits behind the gateway (cmd/gateway) which is the public-facing :8080.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/harshrs641/replayiq/internal/api"
	"github.com/harshrs641/replayiq/internal/kafka"
	"github.com/harshrs641/replayiq/internal/masking"
	"github.com/harshrs641/replayiq/internal/storage"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))

	writeDSN := getEnv("DATABASE_URL", "postgres://replayiq:replayiq_secret@localhost:5432/replayiq?sslmode=disable")
	readDSN := getEnv("DATABASE_READ_URL", writeDSN)
	kafkaBrokers := strings.Split(getEnv("KAFKA_BROKERS", "localhost:9092"), ",")
	port := getEnv("INGEST_PORT", "8081")

	db, err := storage.NewPostgres(writeDSN, readDSN)
	if err != nil {
		slog.Error("postgres connect failed", "error", err)
		os.Exit(1)
	}
	if err := db.Migrate(); err != nil {
		slog.Error("migration failed", "error", err)
		os.Exit(1)
	}

	// Ensure Kafka topics exist (idempotent).
	if err := kafka.EnsureTopics(kafkaBrokers,
		kafka.TopicEventsRaw,
		kafka.TopicEventsMasked,
		kafka.TopicAnalyzeRequested,
	); err != nil {
		slog.Warn("kafka topic setup failed (topics may already exist)", "error", err)
	}

	producer := kafka.NewProducer(kafkaBrokers)
	defer producer.Close()

	var extraMaskClasses []string
	if mc := getEnv("MASK_CLASSES", ""); mc != "" {
		extraMaskClasses = strings.Split(mc, ",")
	}

	handler := api.NewIngestRouter(api.RouterConfig{
		DB:          db,
		Producer:    producer,
		Masking:     masking.DefaultConfig(extraMaskClasses),
		MaskTracker: masking.NewTracker(),
	})

	srv := &http.Server{
		Addr:         fmt.Sprintf(":%s", port),
		Handler:      handler,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		slog.Info("ingest service starting", "port", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("ingest server error", "error", err)
			os.Exit(1)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	slog.Info("ingest service shutting down")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	srv.Shutdown(ctx)
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
