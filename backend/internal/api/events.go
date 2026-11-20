package api

import (
	"encoding/json"
	"github.com/harshrs641/replayiq/internal/ingest"
	"log/slog"
	"net/http"

	"github.com/harshrs641/replayiq/internal/kafka"
	"github.com/harshrs641/replayiq/internal/models"
	"github.com/harshrs641/replayiq/internal/transform"
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

	body, err := readIngestBody(w, req, maxEventBodyBytes)
	if err != nil {
		writeBodyError(w, err)
		return
	}
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

	if batch.ProjectID == "" {
		batch.ProjectID = ingestKey(req)
	}
	if batch.Dropped > 0 {
		slog.Warn("dropped malformed events", "session_id", batch.SessionID, "sdk", batch.SDK, "dropped", batch.Dropped)
	}
	if batch.SessionID == "" {
		writeError(w, http.StatusBadRequest, "session_id is required")
		return
	}
	// Mobile recordings (screenshots or Native DOM) can only be masked on
	// the device.
	if batch.DataMode != "" && batch.DataMode != "masked" && batch.DataMode != "raw" {
		writeError(w, http.StatusBadRequest, `data_mode must be "masked" or "raw"`)
		return
	}
	// Mobile recordings say how they were masked: on the device (masked /
	// v1 device_masked) or not at all (raw, the server builds the masked copy).
	if transform.NeedsTransform(&batch) && !batch.DeviceMasked && batch.DataMode != "raw" {
		writeError(w, http.StatusBadRequest, `mobile recordings must set data_mode ("masked" or "raw") or device_masked`)
		return
	}

	ctx := req.Context()
	if r.cfg.Producer != nil {
		// Kafka mode: count the events now (the AI worker reads the count),
		// then hand the batch over as received; the transformer worker
		// converts, masks and forwards it to storage (package ingest). A
		// failed publish is a 503 so the SDK retries the same batch_id.
		if err := ingest.PublishBatch(r.cfg.Producer, kafka.TopicEventsNative, &batch); err != nil {
			slog.Error("kafka publish events.native failed", "error", err)
			writeError(w, http.StatusServiceUnavailable, "try again")
			return
		}
		r.cfg.DB.IncrementEventCount(ctx, batch.SessionID, len(batch.Events))
	} else {
		// All-in-one server: process and store inline.
		if err := r.ingest().Process(ctx, batch); err != nil {
			slog.Error("process batch failed", "session_id", batch.SessionID, "error", err)
			writeError(w, http.StatusServiceUnavailable, "try again")
			return
		}
		r.cfg.DB.IncrementEventCount(ctx, batch.SessionID, len(batch.Events))
	}

	resp := map[string]any{"status": "accepted"}
	if batch.Dropped > 0 {
		resp["dropped"] = batch.Dropped // tells SDK developers something is off
	}
	writeJSON(w, http.StatusAccepted, resp)
}

// ingest returns the batch processor for the all-in-one server.
func (r *router) ingest() *ingest.Processor {
	if r.cfg.Ingest != nil {
		return r.cfg.Ingest
	}
	return &ingest.Processor{MinIO: r.cfg.MinIO, Masking: r.cfg.Masking, Tracker: r.cfg.MaskTracker,
		PublicAPIURL: "http://localhost:8080"}
}
