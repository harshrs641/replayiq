// Command backfill-index writes the streaming-replay index (time range and
// keyframes, see internal/storage/replay_index.go) into the metadata of
// event batches stored before the index existed. Until then those sessions
// still replay, but their manifest reads every batch in full once per
// query-service process.
//
// Safe to re-run: batches that already carry the index are skipped. Reads
// the same MINIO_* env vars as the server.
//
// Usage:
//
//	go run ./cmd/backfill-index            # both buckets
//	go run ./cmd/backfill-index -dry-run   # only count what would change
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"

	"github.com/harshrs641/replayiq/internal/storage"
)

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, nil)))
	dryRun := flag.Bool("dry-run", false, "only report how many batches would be updated")
	flag.Parse()

	bucket := getEnv("MINIO_BUCKET", "sessions")
	m, err := storage.NewMinIO(
		getEnv("MINIO_ENDPOINT", "localhost:9000"),
		getEnv("MINIO_ACCESS_KEY", "minioadmin"),
		getEnv("MINIO_SECRET_KEY", "minioadmin"),
		bucket, getEnv("MINIO_MASKED_BUCKET", bucket+"-masked"),
		getEnv("MINIO_SECURE", "false") == "true",
	)
	if err != nil {
		slog.Error("minio connect failed", "error", err)
		os.Exit(1)
	}

	failed := 0
	for _, masked := range []bool{false, true} {
		name := "raw"
		if masked {
			name = "masked"
		}
		res, err := m.BackfillIndex(context.Background(), masked, *dryRun, func(f string, a ...any) {
			slog.Warn(fmt.Sprintf(f, a...))
		})
		if err != nil {
			slog.Error("backfill failed", "bucket", name, "error", err)
			os.Exit(1)
		}
		verb := "indexed"
		if *dryRun {
			verb = "would index"
		}
		slog.Info("done", "bucket", name, "scanned", res.Scanned, "already_indexed", res.AlreadyIndexed, verb, res.Updated, "failed", res.Failed)
		failed += res.Failed
	}
	if failed > 0 {
		os.Exit(1)
	}
}

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
