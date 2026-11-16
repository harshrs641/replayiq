package api

// Streaming replay API: lets the player start fast and jump anywhere
// instead of downloading the whole session up front (GET .../replay).
//
//	GET /api/v1/sessions/{id}/replay/manifest
//	    Timeline only, no events: start/end, keyframes (FullSnapshot
//	    timestamps, places playback can start from) and per-batch ranges.
//
//	GET /api/v1/sessions/{id}/replay/events?from=&to=
//	    Events with from <= timestamp < to. Use to extend a range that is
//	    already playing.
//
//	GET /api/v1/sessions/{id}/replay/events?at=&to=
//	    Jump: starts at the last keyframe at or before `at` and makes the
//	    chunk playable on its own (a Meta event is emitted first, retimed to
//	    that keyframe). The response's "from" says where it actually starts.
//
//	GET /api/v1/sessions/{id}/replay/activity
//	    Only navigation (Meta) and SDK-tagged events (clicks, inputs,
//	    console, network) for the activity tabs; skips DOM/screenshot data.
//
// All take masked=true|false like /replay (default true; falls back to the
// raw copy when no masked copy exists, and says so in "masked").

import (
	"fmt"
	"math"
	"net/http"
	"sort"
	"strconv"

	"github.com/harshrs641/replayiq/internal/storage"
)

func (r *router) replayStream(w http.ResponseWriter, req *http.Request, sessionID, part string) {
	if req.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	ctx := req.Context()
	q := req.URL.Query()
	masked := r.useMaskedCopy(ctx, sessionID, q.Get("masked") != "false")

	idx, err := r.cfg.MinIO.SessionIndex(ctx, masked, sessionID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	// Sessions can still be recording; never let a stale timeline be cached.
	w.Header().Set("Cache-Control", "no-store")

	switch part {
	case "manifest":
		writeManifest(w, sessionID, masked, idx)
	case "events":
		r.writeEventRange(w, req, sessionID, masked, idx)
	case "activity":
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"session_id":%q,"masked":%t,"events":[`, sessionID, masked)
		r.cfg.MinIO.StreamEvents(ctx, masked, idx, math.MinInt64, math.MaxInt64, false, storage.ActivityOnly(), w)
		fmt.Fprint(w, "]}")
	default:
		writeError(w, http.StatusNotFound, "unknown replay resource")
	}
}

type replaySegment struct {
	First int64 `json:"first"`
	Last  int64 `json:"last"`
	Count int   `json:"count"`
	Bytes int64 `json:"bytes"`
}

type replayManifest struct {
	SessionID  string          `json:"session_id"`
	Masked     bool            `json:"masked"`
	Start      int64           `json:"start"`
	End        int64           `json:"end"`
	DurationMs int64           `json:"duration_ms"`
	Events     int             `json:"events"`
	Bytes      int64           `json:"bytes"`
	Keyframes  []int64         `json:"keyframes"`
	Segments   []replaySegment `json:"segments"`
}

func buildManifest(sessionID string, masked bool, idx []storage.BatchIndex) replayManifest {
	m := replayManifest{SessionID: sessionID, Masked: masked, Keyframes: storage.Keyframes(idx), Segments: []replaySegment{}}
	if m.Keyframes == nil {
		m.Keyframes = []int64{}
	}
	for i, b := range idx {
		if i == 0 || b.First < m.Start {
			m.Start = b.First
		}
		if b.Last > m.End {
			m.End = b.Last
		}
		m.Events += b.Count
		m.Bytes += b.Bytes
		m.Segments = append(m.Segments, replaySegment{First: b.First, Last: b.Last, Count: b.Count, Bytes: b.Bytes})
	}
	if len(idx) > 0 {
		m.DurationMs = m.End - m.Start
	}
	return m
}

func writeManifest(w http.ResponseWriter, sessionID string, masked bool, idx []storage.BatchIndex) {
	writeJSON(w, http.StatusOK, buildManifest(sessionID, masked, idx))
}

// keyframeAtOrBefore returns the latest keyframe <= at, or the session start
// when there is none (playback then starts from the beginning).
func keyframeAtOrBefore(keyframes []int64, at, start int64) int64 {
	i := sort.Search(len(keyframes), func(i int) bool { return keyframes[i] > at })
	if i == 0 {
		return start
	}
	return keyframes[i-1]
}

func (r *router) writeEventRange(w http.ResponseWriter, req *http.Request, sessionID string, masked bool, idx []storage.BatchIndex) {
	q := req.URL.Query()
	parse := func(name string, def int64) (int64, bool) {
		v := q.Get(name)
		if v == "" {
			return def, true
		}
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			return n, true
		}
		// Players report fractional milliseconds; accept and truncate them.
		f, err := strconv.ParseFloat(v, 64)
		if err != nil || math.IsNaN(f) || math.IsInf(f, 0) {
			return 0, false
		}
		return int64(f), true
	}
	to, ok := parse("to", math.MaxInt64)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid to")
		return
	}

	var from int64
	jump := q.Get("at") != ""
	if jump {
		at, ok := parse("at", 0)
		if !ok {
			writeError(w, http.StatusBadRequest, "invalid at")
			return
		}
		m := buildManifest(sessionID, masked, idx)
		from = keyframeAtOrBefore(m.Keyframes, at, m.Start)
	} else {
		if from, ok = parse("from", math.MinInt64); !ok {
			writeError(w, http.StatusBadRequest, "invalid from")
			return
		}
	}
	if to <= from {
		writeError(w, http.StatusBadRequest, "to must be greater than from")
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	fmt.Fprintf(w, `{"session_id":%q,"masked":%t,"from":%d,"to":%d,"events":[`, sessionID, masked, from, to)
	r.cfg.MinIO.StreamEvents(req.Context(), masked, idx, from, to, jump, nil, w)
	fmt.Fprint(w, "]}")
}
