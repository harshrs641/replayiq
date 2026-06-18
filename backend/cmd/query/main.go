// Command query is the Query API service: read-only HTTP endpoints for the
// dashboard — session listing, replay, semantic search, issues, and Jira.
//
// Listens on :8082 by default (QUERY_PORT to override).
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

	"github.com/harshrs641/replayiq/internal/ai"
	"github.com/harshrs641/replayiq/internal/api"
	"github.com/harshrs641/replayiq/internal/masking"
	"github.com/harshrs641/replayiq/internal/storage"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))

	writeDSN := getEnv("DATABASE_URL", "postgres://replayiq:replayiq_secret@localhost:5432/replayiq?sslmode=disable")
	readDSN := getEnv("DATABASE_READ_URL", writeDSN)
	port := getEnv("QUERY_PORT", "8082")
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
	)

	var extraMaskClasses []string
	if mc := getEnv("MASK_CLASSES", ""); mc != "" {
		extraMaskClasses = strings.Split(mc, ",")
	}

	handler := api.NewQueryRouter(api.RouterConfig{
		DB:      db,
		MinIO:   minio,
		AI:      aiEngine,
		SDKPath: getEnv("SDK_PATH", "./sdk"),
		JiraConfig: api.JiraConfig{
			BaseURL:    getEnv("JIRA_BASE_URL", ""),
			Email:      getEnv("JIRA_EMAIL", ""),
			APIToken:   getEnv("JIRA_API_TOKEN", ""),
			ProjectKey: getEnv("JIRA_PROJECT_KEY", "ENG"),
		},
		Masking:     masking.DefaultConfig(extraMaskClasses),
		MaskTracker: masking.NewTracker(),
	})

	srv := &http.Server{
		Addr:         fmt.Sprintf(":%s", port),
		Handler:      handler,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 60 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	go func() {
		slog.Info("query service starting", "port", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("query server error", "error", err)
			os.Exit(1)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	slog.Info("query service shutting down")
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
