package api

import (
	"encoding/json"
	"net/http"

	"github.com/harshrs641/replayiq/internal/ai"
	"github.com/harshrs641/replayiq/internal/models"
	"github.com/harshrs641/replayiq/internal/storage"
)

// moment is one AI finding placed on the session timeline.
type moment struct {
	ID   string `json:"id,omitempty"` // issue id (issues only)
	Text string `json:"text"`
	// TS: unix ms of the event it refers to; 0 when it couldn't be placed.
	TS int64 `json:"ts"`
	// Source: "ai" (the model cited the event), "matched" (found by matching
	// the text against the events), or "" (not placed).
	Source string `json:"source"`
}

// GET /api/v1/sessions/{id}/moments — when each AI frustration and issue
// happened, for jumping the replay to it. Sessions analysed before findings
// carried a time are matched against their tokenized events on the fly.
func (r *router) sessionMoments(w http.ResponseWriter, req *http.Request, sessionID string) {
	if req.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	sm, err := r.cfg.DB.GetSessionMoments(req.Context(), sessionID)
	if err != nil {
		writeError(w, http.StatusNotFound, "session not found")
		return
	}
	writeJSON(w, http.StatusOK, buildMoments(sessionID, sm))
}

func buildMoments(sessionID string, sm *storage.SessionMoments) map[string]any {
	var tokens []models.TokenizedEvent
	json.Unmarshal([]byte(sm.Tokenized), &tokens)

	place := func(text string, stored int64) moment {
		m := moment{Text: text, TS: stored}
		if stored > 0 {
			m.Source = "ai"
		} else if ts := ai.GroundText(text, tokens); ts > 0 {
			m.TS, m.Source = ts, "matched"
		}
		return m
	}
	frustrations := make([]moment, 0, len(sm.Frustrations))
	for i, f := range sm.Frustrations {
		var stored int64
		if i < len(sm.FrustrationTS) {
			stored = sm.FrustrationTS[i]
		}
		frustrations = append(frustrations, place(f, stored))
	}
	issues := make([]moment, 0, len(sm.Issues))
	for _, is := range sm.Issues {
		m := place(is.Title+". "+is.Description, is.MomentTS)
		m.ID, m.Text = is.ID, is.Title
		issues = append(issues, m)
	}
	return map[string]any{"session_id": sessionID, "frustrations": frustrations, "issues": issues}
}
