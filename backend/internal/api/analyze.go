package api

import (
	"context"
	"time"

	"github.com/harshrs641/replayiq/internal/kafka"
)

// queueAnalysis marks the session as queued and schedules AI analysis.
//
// Kafka (decoupled) mode — Producer != nil:
//   The event is published to Kafka; the processor service consumes it and
//   runs the pipeline.  The HTTP handler returns immediately.
//
// Monolith mode — Producer == nil:
//   Analyzer.AnalyzeAsync is called, which acquires the bounded semaphore
//   and runs the pipeline in a goroutine.
func (r *router) queueAnalysis(ctx context.Context, sessionID string, delay time.Duration) {
	r.cfg.DB.UpdateSessionAIStatus(ctx, sessionID, "queued", "")

	if r.cfg.Producer != nil {
		r.cfg.Producer.Publish(kafka.TopicAnalyzeRequested, sessionID, kafka.AnalyzeRequestedEvent{ //nolint:errcheck
			SessionID: sessionID,
			DelayMs:   delay.Milliseconds(),
		})
		return
	}

	// Monolith mode: run analysis in-process.
	r.cfg.Analyzer.AnalyzeAsync(context.Background(), sessionID, delay)
}
