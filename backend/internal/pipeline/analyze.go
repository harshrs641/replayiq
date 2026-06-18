// Package pipeline contains the AI analysis pipeline used by both the
// monolith (cmd/server) and the decoupled processor service (cmd/processor).
// Keeping the logic here — rather than inside the api package — lets the
// processor import and call it without depending on HTTP handler state.
package pipeline

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/google/uuid"
	"github.com/harshrs641/replayiq/internal/ai"
	"github.com/harshrs641/replayiq/internal/models"
	"github.com/harshrs641/replayiq/internal/storage"
)

// Quality thresholds — sessions below either bar are skipped without calling
// the LLM, saving cost for bounce/bot traffic.
const (
	MinAnalysisDurationMs = 5_000
	MinAnalysisEvents     = 5

	// minioRetryAttempts / minioRetryDelay control how many times Analyze
	// waits for the Storage Worker to flush events to MinIO before giving up.
	// In the decoupled arch there is an inherent lag between the Ingest API
	// publishing events to Kafka and the Storage Worker writing them to MinIO.
	minioRetryAttempts = 6
	minioRetryDelay    = 3 * time.Second
)

// Analyzer runs the full AI analysis pipeline for a session.  It is safe for
// concurrent use; the analysisSem bounds the number of simultaneous Ollama
// calls.
type Analyzer struct {
	db    *storage.Postgres
	minio *storage.MinIO
	ai    *ai.OllamaEngine
	// analysisSem is a counting semaphore: capacity == max concurrent Ollama calls.
	analysisSem chan struct{}
}

func NewAnalyzer(db *storage.Postgres, minio *storage.MinIO, aiEngine *ai.OllamaEngine, concurrency int) *Analyzer {
	if concurrency <= 0 {
		concurrency = 4
	}
	return &Analyzer{
		db:          db,
		minio:       minio,
		ai:          aiEngine,
		analysisSem: make(chan struct{}, concurrency),
	}
}

// AnalyzeAsync acquires a semaphore slot and calls Analyze in a goroutine.
// Used by the monolith (cmd/server) so the HTTP handler returns immediately.
func (a *Analyzer) AnalyzeAsync(ctx context.Context, sessionID string, delay time.Duration) {
	go func() {
		if delay > 0 {
			time.Sleep(delay)
		}
		a.analysisSem <- struct{}{}
		defer func() { <-a.analysisSem }()
		if err := a.Analyze(context.Background(), sessionID); err != nil {
			slog.Error("async analysis failed", "session_id", sessionID, "error", err)
		}
	}()
}

// Analyze runs the full pipeline synchronously and returns any terminal error.
// In the decoupled processor it is called from a Kafka consumer goroutine;
// returning an error causes the processor to log and move on (offset still
// committed — poison-pill protection).
func (a *Analyzer) Analyze(ctx context.Context, sessionID string) error {
	slog.Info("analyzing session", "id", sessionID)
	a.db.UpdateSessionAIStatus(ctx, sessionID, "analyzing", "")

	fail := func(stage string, err error) error {
		slog.Error(stage+" failed", "id", sessionID, "error", err)
		a.db.UpdateSessionAIStatus(ctx, sessionID, "failed", fmt.Sprintf("%s: %v", stage, err))
		return fmt.Errorf("%s: %w", stage, err)
	}

	session, err := a.db.GetSession(ctx, sessionID)
	if err != nil {
		return fail("get session", err)
	}

	if session.DurationMs < MinAnalysisDurationMs || session.EventCount < MinAnalysisEvents {
		slog.Info("skipping analysis — session below quality threshold",
			"id", sessionID,
			"duration_ms", session.DurationMs,
			"event_count", session.EventCount,
		)
		a.db.UpdateSessionAIStatus(ctx, sessionID, "skipped", "below quality threshold")
		return nil
	}

	// Retry loop — in the Kafka architecture the Storage Worker may still be
	// writing events to MinIO when the AI Worker receives the analyze event.
	var batches []models.EventBatch
	for attempt := 1; attempt <= minioRetryAttempts; attempt++ {
		batches, err = a.minio.GetSessionEvents(ctx, sessionID)
		if err == nil && len(batches) > 0 {
			break
		}
		if attempt < minioRetryAttempts {
			slog.Info("waiting for MinIO events",
				"id", sessionID, "attempt", attempt,
				"batches_found", len(batches))
			time.Sleep(minioRetryDelay)
		}
	}
	if len(batches) == 0 {
		return fail("get events", fmt.Errorf("no events in MinIO after %d attempts", minioRetryAttempts))
	}

	// If a previous analysis exists, compare fresh tokenized events to the
	// stored fingerprint — skip the LLM call when events are unchanged.
	var summary *models.SessionSummary
	if session.AITokenized != "" && session.AISummary != "" {
		freshTokenized := ai.TokenizeEvents(batches)
		freshJSON, _ := json.Marshal(freshTokenized)
		if string(freshJSON) == session.AITokenized {
			slog.Info("skipping LLM — events unchanged since last analysis", "id", sessionID)
			summary = &models.SessionSummary{Narrative: session.AISummary}
		}
	}
	if summary == nil {
		summary, err = a.ai.AnalyzeSession(ctx, session, batches)
		if err != nil {
			return fail("ai analysis", err)
		}
	}

	if err := a.db.UpdateSessionAI(ctx, sessionID, summary); err != nil {
		return fail("update session ai", err)
	}

	// Embed in a background goroutine so "complete" is set without waiting.
	go func() {
		embedding, err := a.ai.Embed(context.Background(), "search_document: "+summary.Narrative)
		if err != nil {
			slog.Error("embed session failed", "error", err)
			return
		}
		if err := a.db.UpdateSessionEmbedding(context.Background(), sessionID, embedding); err != nil {
			slog.Error("update session embedding failed", "error", err)
		}
	}()

	for _, detected := range summary.Issues {
		issue := &models.AIIssue{
			ID:          uuid.New().String(),
			SessionID:   sessionID,
			ProjectID:   session.ProjectID,
			Type:        detected.Type,
			Title:       detected.Title,
			Description: detected.Description,
			Severity:    detected.Severity,
			Tags:        detected.Tags,
		}
		if err := a.db.CreateIssue(ctx, issue); err != nil {
			slog.Error("create issue failed", "error", err)
		}
	}

	a.db.UpdateSessionAIStatus(ctx, sessionID, "complete", "")
	slog.Info("session analysis complete", "id", sessionID, "issues", len(summary.Issues))
	return nil
}
