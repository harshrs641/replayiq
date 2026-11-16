package api

import (
	"net/http/httptest"
	"strings"
	"testing"

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
	m := buildManifest("s", true, []storage.BatchIndex{
		{First: 100, Last: 5000, Count: 10, Bytes: 1000, Fulls: []int64{101}},
		{First: 5001, Last: 9000, Count: 5, Bytes: 500, Fulls: []int64{6000}},
	})
	if m.Start != 100 || m.End != 9000 || m.DurationMs != 8900 || m.Events != 15 || m.Bytes != 1500 {
		t.Fatalf("%+v", m)
	}
	if len(m.Keyframes) != 2 || len(m.Segments) != 2 {
		t.Fatalf("%+v", m)
	}
	empty := buildManifest("s", false, nil)
	if empty.Keyframes == nil || empty.Segments == nil || empty.DurationMs != 0 {
		t.Fatalf("empty manifest must serialize lists as [] : %+v", empty)
	}
}

func TestEventRangeAcceptsFractionalMillis(t *testing.T) {
	r := &router{}
	req := httptest.NewRequest("GET", "/x?at=1794327645666.0723&to=abc", nil)
	w := httptest.NewRecorder()
	r.writeEventRange(w, req, "s", true, nil)
	if w.Code != 400 || !strings.Contains(w.Body.String(), "invalid to") {
		t.Fatalf("bad 'to' must be rejected, got %d %s", w.Code, w.Body.String())
	}
	req = httptest.NewRequest("GET", "/x?from=1.5&to=0.5", nil)
	w = httptest.NewRecorder()
	r.writeEventRange(w, req, "s", true, nil)
	if w.Code != 400 || !strings.Contains(w.Body.String(), "greater") {
		t.Fatalf("fractional values must parse (and then fail the range check), got %d %s", w.Code, w.Body.String())
	}
}
