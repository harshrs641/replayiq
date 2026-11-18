package api

import (
	"encoding/json"
	"testing"

	"github.com/harshrs641/replayiq/internal/models"
	"github.com/harshrs641/replayiq/internal/storage"
)

func TestBuildMomentsStoredMatchedAndUnplaced(t *testing.T) {
	tokens, _ := json.Marshal([]models.TokenizedEvent{
		{T: "2026-11-17T10:00:19Z", Action: "rage_click", Target: `button:"Pay now"`},
	})
	out := buildMoments("s", &storage.SessionMoments{
		Tokenized:     string(tokens),
		Frustrations:  []string{"stored", "Rage-clicked Pay now", "vague"},
		FrustrationTS: []int64{123}, // older rows may have fewer entries than frustrations
		Issues:        []*models.AIIssue{{ID: "i1", Title: "Pay now ignored taps", Description: "user rage clicked"}},
	})
	fr := out["frustrations"].([]moment)
	if fr[0].TS != 123 || fr[0].Source != "ai" ||
		fr[1].Source != "matched" || fr[1].TS != 1794909619000 ||
		fr[2].TS != 0 || fr[2].Source != "" {
		t.Fatalf("%+v", fr)
	}
	is := out["issues"].([]moment)
	if is[0].ID != "i1" || is[0].Text != "Pay now ignored taps" || is[0].Source != "matched" {
		t.Fatalf("%+v", is)
	}
}
