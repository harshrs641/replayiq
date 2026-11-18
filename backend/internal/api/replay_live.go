package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"time"
)

// Live replay stream (server-sent events), for sessions still recording:
//
//	GET /api/v1/sessions/{id}/replay/live?after=<unix ms>&masked=
//
// The server checks storage for new batches every liveCheckInterval and
// pushes, in one message, the new manifest and every event stored after
// `after`:
//
//	id: <manifest end>
//	event: update
//	data: {"manifest":{...},"events":[...]}
//
// so the player needs neither manifest polling nor a separate fetch for
// the new events. The id lets a reconnecting EventSource resume where it
// left off (Last-Event-ID). When the session stops being live a last
// update is sent, then "event: end", and the stream closes.
const (
	liveCheckInterval = time.Second
	liveHeartbeat     = 15 * time.Second
	// Streams are recycled after this; EventSource reconnects by itself.
	liveMaxStream = 30 * time.Minute
)

func (r *router) replayLive(w http.ResponseWriter, req *http.Request, sessionID string, masked bool) {
	after, err := liveResumePoint(req)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	ctx, cancel := context.WithTimeout(req.Context(), liveMaxStream)
	defer cancel()

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Accel-Buffering", "no") // nginx and similar: don't buffer
	// Compressed: each update can carry a full page snapshot.
	w, done := withGzip(w, req)
	defer done()
	rc := http.NewResponseController(w)
	w.WriteHeader(http.StatusOK)

	send := func(write func(io.Writer)) bool {
		// The query server's WriteTimeout would cut a long stream: push
		// the deadline forward on every message instead.
		rc.SetWriteDeadline(time.Now().Add(liveHeartbeat * 2))
		var buf bytes.Buffer
		write(&buf)
		if _, err := w.Write(buf.Bytes()); err != nil {
			return false
		}
		return rc.Flush() == nil
	}
	if !send(func(b io.Writer) { io.WriteString(b, "retry: 2000\n\n") }) {
		return
	}

	// Which copy to read is decided once: re-checking (with its wait for
	// a masked copy) every second would stall the stream.
	src := r.replaySourceFor(ctx, sessionID, masked)
	tick := time.NewTicker(liveCheckInterval)
	defer tick.Stop()
	lastSent := time.Now()
	for {
		u, err := r.liveUpdate(ctx, sessionID, src, after)
		if err != nil {
			if ctx.Err() == nil {
				slog.Warn("live replay check failed", "session_id", sessionID, "error", err)
			}
		} else if u != nil {
			if !send(u.write) {
				return
			}
			after, lastSent = u.manifest.End, time.Now()
			if !u.manifest.Live {
				send(func(b io.Writer) { io.WriteString(b, "event: end\ndata: {}\n\n") })
				return
			}
		}
		if time.Since(lastSent) >= liveHeartbeat {
			if !send(func(b io.Writer) { io.WriteString(b, ": ping\n\n") }) {
				return
			}
			lastSent = time.Now()
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

// liveResumePoint: the newest event the client already has, from ?after=
// or, on an EventSource reconnect, the Last-Event-ID header.
func liveResumePoint(req *http.Request) (int64, error) {
	v := req.Header.Get("Last-Event-ID")
	if v == "" {
		v = req.URL.Query().Get("after")
	}
	if v == "" {
		return 0, nil
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		f, ferr := strconv.ParseFloat(v, 64)
		if ferr != nil {
			return 0, fmt.Errorf("invalid after")
		}
		n = int64(f)
	}
	return n, nil
}

type liveMessage struct {
	manifest replayManifest
	events   []byte // JSON array
}

func (u *liveMessage) write(w io.Writer) {
	m, _ := json.Marshal(u.manifest)
	fmt.Fprintf(w, "id: %d\nevent: update\ndata: {\"manifest\":%s,\"events\":", u.manifest.End, m)
	w.Write(u.events)
	io.WriteString(w, "}\n\n")
}

// liveUpdate returns the message to send, or nil when nothing changed and
// the session is still live.
func (r *router) liveUpdate(ctx context.Context, sessionID string, src replaySource, after int64) (*liveMessage, error) {
	idx, err := r.cfg.MinIO.SessionIndex(ctx, src.MaskedBucket, sessionID)
	if err != nil {
		return nil, err
	}
	m := buildManifest(sessionID, src, idx)
	if r.cfg.DB != nil {
		sess, _ := r.cfg.DB.GetSession(ctx, sessionID)
		m.Live = isLive(sess, m.End, time.Now())
	}
	if m.End <= after && m.Live {
		return nil, nil
	}
	var events bytes.Buffer
	events.WriteString("[")
	if m.End > after {
		// SSE data must be one line: compact each event as it's written.
		if _, err := r.cfg.MinIO.StreamEvents(ctx, src.MaskedBucket, idx, after+1, m.End+1, false, nil, &compactWriter{w: &events}); err != nil {
			return nil, err
		}
	}
	events.WriteString("]")
	return &liveMessage{manifest: m, events: events.Bytes()}, nil
}

// compactWriter strips insignificant whitespace (newlines would end an SSE
// data line) from the JSON values StreamEvents writes, one per Write.
type compactWriter struct{ w *bytes.Buffer }

func (c *compactWriter) Write(p []byte) (int, error) {
	if bytes.IndexAny(p, "\r\n") < 0 {
		return c.w.Write(p)
	}
	if err := json.Compact(c.w, p); err != nil {
		return 0, err
	}
	return len(p), nil
}
