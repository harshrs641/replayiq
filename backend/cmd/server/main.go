package main

import (
	"context"
	"fmt"
	"github.com/harshrs641/replayiq/internal/ingest"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/harshrs641/replayiq/internal/ai"
	"github.com/harshrs641/replayiq/internal/api"
	"github.com/harshrs641/replayiq/internal/masking"
	"github.com/harshrs641/replayiq/internal/pipeline"
	"github.com/harshrs641/replayiq/internal/storage"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	cfg := loadConfig()

	// ─── Storage ─────────────────────────────────────────────────────────────
	db, err := storage.NewPostgres(cfg.DatabaseURL, cfg.DatabaseReadURL)
	if err != nil {
		slog.Error("failed to connect to postgres", "error", err)
		os.Exit(1)
	}
	if err := db.Migrate(); err != nil {
		slog.Error("migration failed", "error", err)
		os.Exit(1)
	}

	minio, err := storage.NewMinIO(cfg.MinIOEndpoint, cfg.MinIOAccessKey, cfg.MinIOSecretKey, cfg.MinIOBucket, cfg.MinIOMaskedBucket, cfg.MinIOSecure)
	if err != nil {
		slog.Error("failed to connect to minio", "error", err)
		os.Exit(1)
	}

	// ─── Retention ───────────────────────────────────────────────────────────
	// Deletes expired sessions (stored events and rows) now and hourly.
	retention, err := pipeline.ParseRetention(cfg.SessionRetentionDays, os.Getenv("SESSION_RETENTION_DAYS_BY_PROJECT"))
	if err != nil {
		slog.Error("invalid retention config", "error", err)
		os.Exit(1)
	}
	go pipeline.RunRetention(context.Background(), pipeline.StorageRetention{DB: db, MinIO: minio}, retention, time.Hour)

	// ─── AI Engine ───────────────────────────────────────────────────────────
	aiEngine := ai.NewOllamaEngine(cfg.OllamaEndpoint, cfg.OllamaModel, cfg.EmbeddingModel).
		WithModelTiering(cfg.OllamaSmallModel, cfg.OllamaLargeModel)

	// ─── Masking ─────────────────────────────────────────────────────────────
	var extraMaskClasses []string
	if cfg.MaskClasses != "" {
		extraMaskClasses = strings.Split(cfg.MaskClasses, ",")
	}

	// ─── Analysis pipeline ───────────────────────────────────────────────────
	analyzer := pipeline.NewAnalyzer(db, minio, aiEngine, cfg.AnalysisConcurrency)

	// ─── HTTP Server ─────────────────────────────────────────────────────────
	tracker := masking.NewTracker()
	router := api.NewRouter(api.RouterConfig{
		DB:       db,
		MinIO:    minio,
		AI:       aiEngine,
		Analyzer: analyzer,
		SDKPath:  cfg.SDKPath,
		JiraConfig: api.JiraConfig{
			BaseURL:    cfg.JiraBaseURL,
			Email:      cfg.JiraEmail,
			APIToken:   cfg.JiraAPIToken,
			ProjectKey: cfg.JiraProjectKey,
		},
		Masking:     masking.DefaultConfig(extraMaskClasses),
		MaskTracker: tracker,
		Ingest: &ingest.Processor{MinIO: minio, Masking: masking.DefaultConfig(extraMaskClasses), Tracker: tracker,
			PublicAPIURL: getEnv("PUBLIC_API_URL", "http://localhost:"+cfg.Port)},
	})

	srv := &http.Server{
		Addr:         fmt.Sprintf(":%s", cfg.Port),
		Handler:      router,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// ─── Graceful Shutdown ───────────────────────────────────────────────────
	go func() {
		slog.Info("ReplayIQ server starting", "port", cfg.Port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("server error", "error", err)
			os.Exit(1)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	slog.Info("Shutting down server...")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	srv.Shutdown(ctx)
	slog.Info("Server stopped")
}

type Config struct {
	Port              string
	DatabaseURL       string
	DatabaseReadURL   string
	MinIOEndpoint     string
	MinIOAccessKey    string
	MinIOSecretKey    string
	MinIOBucket       string
	MinIOMaskedBucket string
	MinIOSecure       bool
	OllamaEndpoint    string
	OllamaModel       string
	OllamaSmallModel  string
	OllamaLargeModel  string
	EmbeddingModel    string
	JiraBaseURL       string
	JiraEmail         string
	JiraAPIToken      string
	JiraProjectKey    string
	SDKPath           string
	// MaskClasses is a comma-separated list of extra CSS class names (on
	// top of the built-in "riq-mask") that mark an element as sensitive
	// for the server-side masked replay copy. See internal/masking.
	MaskClasses          string
	AnalysisConcurrency  int
	SessionRetentionDays int
}

func loadConfig() Config {
	bucket := getEnv("MINIO_BUCKET", "sessions")
	databaseURL := getEnv("DATABASE_URL", "postgres://replayiq:replayiq@localhost:5432/replayiq?sslmode=disable")
	return Config{
		Port:                 getEnv("PORT", "8080"),
		DatabaseURL:          databaseURL,
		DatabaseReadURL:      getEnv("DATABASE_READ_URL", databaseURL),
		MinIOEndpoint:        getEnv("MINIO_ENDPOINT", "localhost:9000"),
		MinIOAccessKey:       getEnv("MINIO_ACCESS_KEY", "minioadmin"),
		MinIOSecretKey:       getEnv("MINIO_SECRET_KEY", "minioadmin"),
		MinIOBucket:          bucket,
		MinIOMaskedBucket:    getEnv("MINIO_MASKED_BUCKET", bucket+"-masked"),
		MinIOSecure:          getEnv("MINIO_SECURE", "false") == "true",
		OllamaEndpoint:       getEnv("OLLAMA_ENDPOINT", "http://localhost:11434"),
		OllamaModel:          getEnv("OLLAMA_MODEL", "llama3.1:8b"),
		OllamaSmallModel:     getEnv("OLLAMA_SMALL_MODEL", ""),
		OllamaLargeModel:     getEnv("OLLAMA_LARGE_MODEL", ""),
		EmbeddingModel:       getEnv("EMBEDDING_MODEL", "nomic-embed-text"),
		JiraBaseURL:          getEnv("JIRA_BASE_URL", ""),
		JiraEmail:            getEnv("JIRA_EMAIL", ""),
		JiraAPIToken:         getEnv("JIRA_API_TOKEN", ""),
		JiraProjectKey:       getEnv("JIRA_PROJECT_KEY", "ENG"),
		SDKPath:              getEnv("SDK_PATH", "./sdk"),
		MaskClasses:          getEnv("MASK_CLASSES", ""),
		AnalysisConcurrency:  getEnvInt("ANALYSIS_CONCURRENCY", 0),
		SessionRetentionDays: getEnvInt("SESSION_RETENTION_DAYS", 0),
	}
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
