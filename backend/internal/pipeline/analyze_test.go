package pipeline

import (
	"encoding/json"
	"testing"

	"github.com/harshrs641/replayiq/internal/ai"
	"github.com/harshrs641/replayiq/internal/models"
)

func TestUnchangedSinceLastAnalysis(t *testing.T) {
	batches := []models.EventBatch{{Events: []models.RRWebEvent{
		{Type: 5, Subtype: "js_error", Message: "boom", Timestamp: 1_700_000_000_000},
		{Type: 5, Subtype: "rage_click", Selector: "#pay", Timestamp: 1_700_000_001_000},
	}}}
	fp, _ := json.Marshal(ai.TokenizeEvents(batches))

	prev := &models.Session{AISummary: "User failed to pay", AITokenized: string(fp)}
	if !UnchangedSinceLastAnalysis(prev, batches) {
		t.Fatal("same events: want unchanged")
	}

	more := append([]models.EventBatch{}, batches...)
	more = append(more, models.EventBatch{Events: []models.RRWebEvent{
		{Type: 5, Subtype: "network", Status: 500, URL: "/api/pay", Timestamp: 1_700_000_002_000},
	}})
	if UnchangedSinceLastAnalysis(prev, more) {
		t.Fatal("new events: want changed")
	}

	if UnchangedSinceLastAnalysis(&models.Session{AITokenized: string(fp)}, batches) {
		t.Fatal("no previous summary: want changed")
	}
}
