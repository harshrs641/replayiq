// Command backfill-mask creates the redacted "masked" copy of every
// session's events that doesn't have one yet - i.e. every session recorded
// before the masked-replay feature shipped (see internal/masking). Without
// this, those sessions only show up in the replay viewer's "Masked" toggle
// via the raw-data fallback in sessions.go, which means nothing is actually
// redacted for them.
//
// Safe to re-run: sessions that already have a masked copy are skipped
// unless -force is passed. Reads the same env vars as the server
// (DATABASE_URL, MINIO_*, MASK_CLASSES).
//
// Usage:
//
//	go run ./cmd/backfill-mask
//	go run ./cmd/backfill-mask -force   # re-mask everything, even sessions already masked
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"strings"

	"github.com/harshrs641/replayiq/internal/masking"
	"github.com/harshrs641/replayiq/internal/storage"
)

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, nil)))

	force := flag.Bool("force", false, "re-mask sessions that already have a masked copy")
	flag.Parse()

	bucket := getEnv("MINIO_BUCKET", "sessions")
	maskedBucket := getEnv("MINIO_MASKED_BUCKET", bucket+"-masked")

	databaseURL := getEnv("DATABASE_URL", "postgres://replayiq:replayiq@localhost:5432/replayiq?sslmode=disable")
	db, err := storage.NewPostgres(databaseURL, "")
	if err != nil {
		slog.Error("postgres connect failed", "error", err)
		os.Exit(1)
	}

	minio, err := storage.NewMinIO(
		getEnv("MINIO_ENDPOINT", "localhost:9000"),
		getEnv("MINIO_ACCESS_KEY", "minioadmin"),
		getEnv("MINIO_SECRET_KEY", "minioadmin"),
		bucket, maskedBucket,
		getEnv("MINIO_SECURE", "false") == "true",
	)
	if err != nil {
		slog.Error("minio connect failed", "error", err)
		os.Exit(1)
	}

	var extraClasses []string
	if mc := getEnv("MASK_CLASSES", ""); mc != "" {
		extraClasses = strings.Split(mc, ",")
	}
	cfg := masking.DefaultConfig(extraClasses)
	// One tracker shared across all sessions: it keys its sensitive-node-id
	// state by session id internally, so there's no cross-session leakage -
	// this just avoids allocating one per session for no reason.
	tracker := masking.NewTracker()

	ctx := context.Background()
	ids, err := db.ListAllSessionIDs(ctx)
	if err != nil {
		slog.Error("listing sessions failed", "error", err)
		os.Exit(1)
	}

	var maskedCount, skipped, failed int
	for _, id := range ids {
		existing, err := minio.GetSessionMaskedEvents(ctx, id)
		if err == nil && len(existing) > 0 {
			if !*force {
				skipped++
				continue
			}
			// StoreMaskedEvents always writes a fresh timestamped key, so
			// without clearing the old ones first, -force would leave
			// stale objects behind and double up events on replay.
			if err := minio.DeleteSessionMaskedEvents(ctx, id); err != nil {
				slog.Error("delete stale masked events failed", "session_id", id, "error", err)
				failed++
				continue
			}
		}

		raw, err := minio.GetSessionEvents(ctx, id)
		if err != nil || len(raw) == 0 {
			skipped++
			continue
		}

		ok := true
		for i := range raw {
			batch := raw[i]
			batch.SessionID = id // guard against any legacy batch missing it
			m := masking.MaskBatch(tracker, &batch, cfg)
			if _, err := minio.StoreMaskedEvents(ctx, id, m); err != nil {
				slog.Error("store masked failed", "session_id", id, "error", err)
				ok = false
			}
		}
		if ok {
			maskedCount++
			fmt.Printf("masked %s (%d batch(es))\n", id, len(raw))
		} else {
			failed++
		}
	}

	fmt.Printf("\ndone: %d masked, %d skipped (already masked or no events), %d failed (of %d total sessions)\n",
		maskedCount, skipped, failed, len(ids))
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
