package api

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"

	"github.com/harshrs641/replayiq/internal/kafka"
	"github.com/harshrs641/replayiq/internal/masking"
	"github.com/harshrs641/replayiq/internal/models"
)

// maxEventBodyBytes caps a single ingest POST at 5 MB — enough for a
// dense 5-second flush from any real browser session.
const maxEventBodyBytes = 5 << 20

// POST /api/v1/events — ingest event batch
func (r *router) handleEvents(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	req.Body = http.MaxBytesReader(w, req.Body, maxEventBodyBytes)
	body, _ := io.ReadAll(req.Body)
	var batch models.EventBatch
	if err := json.Unmarshal(body, &batch); err != nil {
		preview := body
		if len(preview) > 500 {
			preview = preview[:500]
		}
		slog.Error("decode events batch failed", "error", err, "body_len", len(body), "body_preview", string(preview))
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}

	ctx := req.Context()

	if r.cfg.Producer != nil {
		// Decoupled (Kafka) mode:
		// 1. Increment PG event_count synchronously — the AI Worker reads this
		//    later to know how many events to expect from MinIO.
		r.cfg.DB.IncrementEventCount(ctx, batch.SessionID, len(batch.Events))

		// 2. Mask and publish both copies to Kafka; Storage Worker writes them
		//    to MinIO.
		masked := masking.MaskBatch(r.cfg.MaskTracker, &batch, r.cfg.Masking)
		if err := r.cfg.Producer.Publish(kafka.TopicEventsRaw, batch.SessionID, &batch); err != nil {
			slog.Error("kafka publish events.raw failed", "error", err)
		}
		if err := r.cfg.Producer.Publish(kafka.TopicEventsMasked, batch.SessionID, masked); err != nil {
			slog.Error("kafka publish events.masked failed", "error", err)
		}
	} else {
		// Monolith mode: write directly to MinIO.
		if _, err := r.cfg.MinIO.StoreEvents(ctx, batch.SessionID, &batch); err != nil {
			slog.Error("minio store failed", "error", err)
		}
		masked := masking.MaskBatch(r.cfg.MaskTracker, &batch, r.cfg.Masking)
		if _, err := r.cfg.MinIO.StoreMaskedEvents(ctx, batch.SessionID, masked); err != nil {
			slog.Error("minio masked store failed", "error", err)
		}
		r.cfg.DB.IncrementEventCount(ctx, batch.SessionID, len(batch.Events))
	}

	writeJSON(w, http.StatusAccepted, map[string]string{"status": "accepted"})
}
