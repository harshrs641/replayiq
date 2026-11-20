package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/harshrs641/replayiq/internal/models"
)

// Sub-resource actions under /api/v1/sessions/{id}/...
const (
	actionEnd     = "end"
	actionAnalyze = "analyze"
	actionReplay  = "replay"
	actionMoments = "moments"
)

// POST /api/v1/sessions — create session
// GET  /api/v1/sessions?project_id=&limit=&offset= — list sessions
func (r *router) handleSessions(w http.ResponseWriter, req *http.Request) {
	switch req.Method {
	case http.MethodPost:
		r.createSession(w, req)
	case http.MethodGet:
		r.listSessions(w, req)
	}
}

func (r *router) createSession(w http.ResponseWriter, req *http.Request) {
	body, err := readIngestBody(w, req, 64<<10)
	if err != nil {
		writeBodyError(w, err)
		return
	}
	var s models.Session
	if err := json.Unmarshal(body, &s); err != nil || s.ID == "" {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if s.ProjectID == "" {
		s.ProjectID = ingestKey(req)
	}
	s.StoragePath = fmt.Sprintf("sessions/%s", s.ID)
	if err := r.cfg.DB.CreateSession(req.Context(), &s); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"session_id": s.ID})
}

func (r *router) listSessions(w http.ResponseWriter, req *http.Request) {
	projectID := req.URL.Query().Get("project_id")
	limit, _ := strconv.Atoi(req.URL.Query().Get("limit"))
	offset, _ := strconv.Atoi(req.URL.Query().Get("offset"))
	if limit == 0 {
		limit = 20
	}

	sessions, total, err := r.cfg.DB.ListSessions(req.Context(), projectID, limit, offset)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"sessions": sessions, "total": total})
}

// /api/v1/sessions/{id}
// /api/v1/sessions/{id}/end
// /api/v1/sessions/{id}/analyze
// /api/v1/sessions/{id}/replay
func (r *router) handleSessionByID(w http.ResponseWriter, req *http.Request) {
	path := strings.TrimPrefix(req.URL.Path, "/api/v1/sessions/")
	parts := strings.Split(path, "/")
	sessionID := parts[0]

	if len(parts) == 1 {
		r.getSession(w, req, sessionID)
		return
	}

	switch parts[1] {
	case actionEnd:
		r.endSession(w, req, sessionID)
	case actionAnalyze:
		r.triggerAnalysis(w, req, sessionID)
	case actionMoments:
		r.sessionMoments(w, req, sessionID)
	case actionReplay:
		if len(parts) == 3 && parts[2] != "" {
			r.replayStream(w, req, sessionID, parts[2])
			return
		}
		r.replaySession(w, req, sessionID)
	default:
		writeError(w, http.StatusNotFound, "unknown action")
	}
}

// GET /api/v1/sessions/{id}
func (r *router) getSession(w http.ResponseWriter, req *http.Request, sessionID string) {
	s, err := r.cfg.DB.GetSession(req.Context(), sessionID)
	if err != nil {
		writeError(w, http.StatusNotFound, "session not found")
		return
	}
	writeJSON(w, http.StatusOK, s)
}

// POST /api/v1/sessions/{id}/end
func (r *router) endSession(w http.ResponseWriter, req *http.Request, sessionID string) {
	var body struct {
		EndedAt    string `json:"ended_at"`
		DurationMs int64  `json:"duration_ms"`
	}
	if raw, err := readIngestBody(w, req, 16<<10); err == nil {
		json.Unmarshal(raw, &body)
	}
	t, _ := time.Parse(time.RFC3339, body.EndedAt)
	r.cfg.DB.EndSession(req.Context(), sessionID, t, body.DurationMs)
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})

	// Trigger AI analysis automatically once the session ends.
	// The end-of-session ping and the final event flush are independent,
	// un-awaited requests from the browser (both fire from beforeunload),
	// so the last batch may not have landed yet — the 2-second delay gives
	// the Storage Worker (Kafka mode) or the direct MinIO write (monolith)
	// time to complete before the pipeline reads events back out.
	//
	// Use context.Background() so the job is not cancelled when the HTTP
	// request context closes (which happens immediately after this returns).
	r.queueAnalysis(context.Background(), sessionID, 2*time.Second)
}

// POST /api/v1/sessions/{id}/analyze — trigger AI analysis.
// If the session is already complete the request is a no-op so clicking
// "Analyze" multiple times does not enqueue duplicate LLM work.
func (r *router) triggerAnalysis(w http.ResponseWriter, req *http.Request, sessionID string) {
	s, err := r.cfg.DB.GetSession(req.Context(), sessionID)
	if err != nil {
		writeError(w, http.StatusNotFound, "session not found")
		return
	}
	if s.AIStatus == "complete" {
		writeJSON(w, http.StatusOK, map[string]string{"status": "already_complete", "session_id": sessionID})
		return
	}
	r.queueAnalysis(context.Background(), sessionID, 0)
	writeJSON(w, http.StatusAccepted, map[string]string{"status": "analysis_queued", "session_id": sessionID})
}

// GET /api/v1/sessions/{id}/replay?masked=true|false — stream all event
// batches for replay. Defaults to the redacted copy (masked=true) so the
// safe view is what loads unless the dashboard's toggle explicitly asks
// for raw values.
//
// Batches are piped from MinIO directly into the response body one at a
// time, so the handler never holds the full session in memory regardless
// of session size.
func (r *router) replaySession(w http.ResponseWriter, req *http.Request, sessionID string) {
	src := r.replaySourceFor(req.Context(), sessionID, req.URL.Query().Get("masked") != "false")
	ctx := req.Context()

	w.Header().Set("Content-Type", "application/json")
	w, done := withGzip(w, req)
	defer done()
	w.WriteHeader(http.StatusOK)

	fmt.Fprintf(w, `{"session_id":%q,"masked":%t,"device_masked":%t,"batches":[`, sessionID, src.Masked(), src.DeviceMasked)

	if src.MaskedBucket {
		r.cfg.MinIO.StreamSessionMaskedEvents(ctx, sessionID, w)
	} else {
		r.cfg.MinIO.StreamSessionEvents(ctx, sessionID, w)
	}

	fmt.Fprint(w, "]}")
}

// replaySource says which stored copy a replay request is served from.
type replaySource struct {
	// MaskedBucket: serve the server-masked copy (else the raw bucket).
	MaskedBucket bool
	// DeviceMasked: the recorder masked the session on the device, so the
	// single raw copy is already the masked view.
	DeviceMasked bool
}

// Masked reports whether what is served is masked.
func (s replaySource) Masked() bool { return s.MaskedBucket || s.DeviceMasked }

func (r *router) replaySourceFor(ctx context.Context, sessionID string, masked bool) replaySource {
	if masked && !r.cfg.MinIO.HasMaskedEvents(ctx, sessionID) && r.cfg.MinIO.IsDeviceMasked(ctx, sessionID) {
		// No masked copy is ever written for these; don't wait for one.
		return replaySource{DeviceMasked: true}
	}
	return replaySource{MaskedBucket: r.useMaskedCopy(ctx, sessionID, masked)}
}

// useMaskedCopy reports whether the replay should be served from the masked
// bucket.
func (r *router) useMaskedCopy(ctx context.Context, sessionID string, masked bool) bool {
	// When masked is requested we briefly poll for the masked objects: in the
	// async (Kafka) pipeline the storage worker writes them shortly after
	// ingest, so there is a small window right after session end where the
	// objects may not have arrived yet. Polling for up to ~3 s avoids silently
	// falling back to raw and showing unredacted data to the user.
	hasMasked := false
	if masked {
		deadline := time.Now().Add(3 * time.Second)
	poll:
		for {
			if r.cfg.MinIO.HasMaskedEvents(ctx, sessionID) {
				hasMasked = true
				break
			}
			if time.Now().After(deadline) {
				break
			}
			select {
			case <-ctx.Done():
				break poll
			case <-time.After(300 * time.Millisecond):
			}
		}
	}
	// Fall back to raw only if: caller explicitly asked for raw, or masked
	// events still don't exist (session predates masking feature).
	return masked && hasMasked
}

// GET /api/v1/sessions/search?project_id=&q=&limit= — semantic search over
// previously analyzed sessions, ranked by embedding similarity to q.
func (r *router) handleSessionSearch(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	projectID := req.URL.Query().Get("project_id")
	query := req.URL.Query().Get("q")
	if query == "" {
		writeError(w, http.StatusBadRequest, "missing q parameter")
		return
	}
	limit, _ := strconv.Atoi(req.URL.Query().Get("limit"))
	if limit == 0 {
		limit = 20
	}

	// nomic-embed-text expects queries and documents to be embedded with
	// different prefixes for best retrieval quality.  Cache the result so
	// repeated searches for the same term skip the Ollama round-trip.
	cacheKey := "search_query: " + query
	embedding, cached := r.queryEmbedCache.get(cacheKey)
	if !cached {
		var err error
		embedding, err = r.cfg.AI.Embed(req.Context(), cacheKey)
		if err != nil {
			writeError(w, http.StatusInternalServerError, fmt.Sprintf("embedding failed: %v", err))
			return
		}
		r.queryEmbedCache.set(cacheKey, embedding)
	}

	sessions, err := r.cfg.DB.SearchSessions(req.Context(), projectID, embedding, limit)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"sessions": sessions, "query": query})
}
