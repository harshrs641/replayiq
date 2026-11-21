package api

import (
	"encoding/json"
	"log/slog"
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
// happened, for jumping the replay to it. Findings from analyses made
// before they carried a time are matched against the tokenized events the
// first time they are asked for, and the result is saved.
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
	out, placed := buildMoments(sessionID, sm)
	if placed.any() {
		if err := r.cfg.DB.SaveMoments(req.Context(), sessionID, placed.frustrationTS, placed.frustrationSrc, placed.issues); err != nil {
			slog.Warn("save moments failed", "session_id", sessionID, "error", err)
		}
	}
	writeJSON(w, http.StatusOK, out)
}

// placedMoments are findings buildMoments placed now (not stored yet).
type placedMoments struct {
	frustrationTS  []int64 // full arrays, when any frustration was placed
	frustrationSrc []string
	issues         []*models.AIIssue
}

func (p placedMoments) any() bool { return p.frustrationTS != nil || len(p.issues) > 0 }

func buildMoments(sessionID string, sm *storage.SessionMoments) (map[string]any, placedMoments) {
	var tokens []models.TokenizedEvent
	tokensLoaded := false
	ground := func(text string) (int64, string) {
		if !tokensLoaded {
			json.Unmarshal([]byte(sm.Tokenized), &tokens)
			tokensLoaded = true
		}
		return ai.Ground(text, tokens)
	}
	// Stored times without a source predate sources: they came from the
	// model's analysis.
	known := func(ts int64, src string) (string, bool) {
		if src != "" {
			return src, true
		}
		if ts > 0 {
			return ai.MomentAI, true
		}
		return "", false
	}
	toMoment := func(text string, ts int64, src string) moment {
		if src == ai.MomentNone {
			src = ""
		}
		return moment{Text: text, TS: ts, Source: src}
	}

	var placed placedMoments
	n := len(sm.Frustrations)
	ts, src := make([]int64, n), make([]string, n)
	frustrations := make([]moment, 0, n)
	for i, f := range sm.Frustrations {
		if i < len(sm.FrustrationTS) {
			ts[i] = sm.FrustrationTS[i]
		}
		if i < len(sm.FrustrationSrc) {
			src[i] = sm.FrustrationSrc[i]
		}
		s, ok := known(ts[i], src[i])
		if !ok {
			ts[i], s = ground(f)
			placed.frustrationTS, placed.frustrationSrc = ts, src
		}
		src[i] = s
		frustrations = append(frustrations, toMoment(f, ts[i], s))
	}

	issues := make([]moment, 0, len(sm.Issues))
	for _, is := range sm.Issues {
		s, ok := known(is.MomentTS, is.MomentSource)
		if !ok {
			is.MomentTS, s = ground(is.Title + ". " + is.Description)
			is.MomentSource = s
			placed.issues = append(placed.issues, is)
		}
		m := toMoment(is.Title, is.MomentTS, s)
		m.ID = is.ID
		issues = append(issues, m)
	}
	return map[string]any{"session_id": sessionID, "frustrations": frustrations, "issues": issues}, placed
}
