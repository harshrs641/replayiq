package ingest

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/harshrs641/replayiq/internal/models"
)

func TestSplitBatch(t *testing.T) {
	b := &models.EventBatch{SessionID: "s", ProjectID: "p", BatchID: "s-000001", DeviceMasked: true, Platform: "ios",
		CustomEvents: []models.CustomEvent{{Name: "checkout"}}}
	for i := 0; i < 10; i++ {
		b.Events = append(b.Events, models.RRWebEvent{Type: 5, Subtype: "console", Message: strings.Repeat("x", 300), Timestamp: int64(i)})
	}
	parts := SplitBatch(b, 1000)
	if len(parts) < 3 {
		t.Fatalf("want several parts, got %d", len(parts))
	}
	n := 0
	for i, p := range parts {
		raw, _ := json.Marshal(p)
		if len(raw) > 1300 {
			t.Errorf("part %d is %d bytes", i, len(raw))
		}
		if p.BatchID != "s-000001.p"+string(rune('1'+i)) || p.SessionID != "s" || !p.DeviceMasked || p.Platform != "ios" {
			t.Fatalf("part %d header %+v", i, p)
		}
		for _, e := range p.Events {
			if e.Timestamp != int64(n) {
				t.Fatal("order lost")
			}
			n++
		}
	}
	if n != 10 || len(parts[0].CustomEvents) != 1 || len(parts[1].CustomEvents) != 0 {
		t.Fatalf("events %d, custom events in first part only", n)
	}
	// Retrying the same batch gives the same parts.
	again := SplitBatch(b, 1000)
	if len(again) != len(parts) || again[1].BatchID != parts[1].BatchID {
		t.Fatal("parts must be stable across retries")
	}
	// A small batch is untouched; one huge event stays one part.
	if got := SplitBatch(b, 1<<20); len(got) != 1 || got[0] != b {
		t.Fatal("small batch must pass through")
	}
	big := &models.EventBatch{SessionID: "s", Events: []models.RRWebEvent{{Type: 5, Message: strings.Repeat("y", 5000)}}}
	if got := SplitBatch(big, 1000); len(got) != 1 {
		t.Fatalf("one oversized event: %d parts", len(got))
	}
}
