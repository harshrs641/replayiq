package api

import (
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/harshrs641/replayiq/internal/models"
	"github.com/harshrs641/replayiq/internal/storage"
)

func TestKeyframeAtOrBefore(t *testing.T) {
	kf := []int64{100, 30100, 60100}
	for _, c := range []struct{ at, want int64 }{
		{50, 7}, {100, 100}, {30099, 100}, {30100, 30100}, {99999, 60100},
	} {
		if got := keyframeAtOrBefore(kf, c.at, 7); got != c.want {
			t.Errorf("at %d: got %d want %d", c.at, got, c.want)
		}
	}
	if got := keyframeAtOrBefore(nil, 500, 7); got != 7 {
		t.Errorf("no keyframes should start at session start, got %d", got)
	}
}

func TestBuildManifest(t *testing.T) {
	m := buildManifest("s", replaySource{MaskedBucket: true}, []storage.BatchIndex{
		{First: 100, Last: 5000, Count: 10, Bytes: 1000, Fulls: []int64{101}},
		{First: 5001, Last: 9000, Count: 5, Bytes: 500, Fulls: []int64{6000}},
	})
	if m.Start != 100 || m.End != 9000 || m.DurationMs != 8900 || m.Events != 15 || m.Bytes != 1500 {
		t.Fatalf("%+v", m)
	}
	if len(m.Keyframes) != 2 || len(m.Segments) != 2 {
		t.Fatalf("%+v", m)
	}
	empty := buildManifest("s", replaySource{}, nil)
	if empty.Keyframes == nil || empty.Segments == nil || empty.DurationMs != 0 {
		t.Fatalf("empty manifest must serialize lists as [] : %+v", empty)
	}
}

func TestEventRangeAcceptsFractionalMillis(t *testing.T) {
	r := &router{}
	req := httptest.NewRequest("GET", "/x?at=1794327645666.0723&to=abc", nil)
	w := httptest.NewRecorder()
	r.writeEventRange(w, req, "s", replaySource{MaskedBucket: true}, nil)
	if w.Code != 400 || !strings.Contains(w.Body.String(), "invalid to") {
		t.Fatalf("bad 'to' must be rejected, got %d %s", w.Code, w.Body.String())
	}
	req = httptest.NewRequest("GET", "/x?from=1.5&to=0.5", nil)
	w = httptest.NewRecorder()
	r.writeEventRange(w, req, "s", replaySource{MaskedBucket: true}, nil)
	if w.Code != 400 || !strings.Contains(w.Body.String(), "greater") {
		t.Fatalf("fractional values must parse (and then fail the range check), got %d %s", w.Code, w.Body.String())
	}
}

func TestIsLive(t *testing.T) {
	now := time.Date(2026, 11, 17, 12, 0, 0, 0, time.UTC)
	ago := func(d time.Duration) *time.Time { x := now.Add(-d); return &x }
	recent := now.Add(-30 * time.Second).UnixMilli()
	stale := now.Add(-10 * time.Minute).UnixMilli()
	for name, c := range map[string]struct {
		s    *models.Session
		last int64
		want bool
	}{
		"recording":                 {&models.Session{}, recent, true},
		"no end signal, gone quiet": {&models.Session{}, stale, false},
		"just ended (settling)":     {&models.Session{EndedAt: ago(30 * time.Second)}, recent, true},
		"ended long ago":            {&models.Session{EndedAt: ago(time.Hour)}, recent, false},
		"unknown session, recent":   {nil, recent, true},
		"no events":                 {&models.Session{}, 0, false},
	} {
		if got := isLive(c.s, c.last, now); got != c.want {
			t.Errorf("%s: got %v want %v", name, got, c.want)
		}
	}
}

func TestReplayCacheControl(t *testing.T) {
	old := time.Now().Add(-time.Hour)
	fresh := time.Now()
	if replayCacheControl(nil, "events") != "no-store" ||
		replayCacheControl(&models.Session{}, "events") != "no-store" ||
		replayCacheControl(&models.Session{EndedAt: &fresh}, "events") != "no-store" {
		t.Fatal("unfinished or settling sessions must not be cached")
	}
	if replayCacheControl(&models.Session{EndedAt: &old}, "manifest") != "private, max-age=300" ||
		replayCacheControl(&models.Session{EndedAt: &old}, "events") != "private, max-age=86400" {
		t.Fatal("finished sessions: short manifest cache, long chunk cache")
	}
}
