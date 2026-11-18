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
	out, placed := buildMoments("s", &storage.SessionMoments{
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

	// What was placed now is returned for saving, including "none" for the
	// finding that couldn't be placed (so it isn't retried every time).
	if got := placed.frustrationSrc; len(got) != 3 || got[0] != "ai" || got[1] != "matched" || got[2] != "none" {
		t.Fatalf("frustration sources to save: %v", got)
	}
	if placed.frustrationTS[1] != 1794909619000 || len(placed.issues) != 1 || placed.issues[0].MomentSource != "matched" {
		t.Fatalf("%+v", placed)
	}
}

func TestBuildMomentsUsesSavedResultsWithoutMatching(t *testing.T) {
	out, placed := buildMoments("s", &storage.SessionMoments{
		Tokenized:      "not even json: must not be needed",
		Frustrations:   []string{"Rage-clicked Pay now", "vague"},
		FrustrationTS:  []int64{1794909619000, 0},
		FrustrationSrc: []string{"matched", "none"},
		Issues:         []*models.AIIssue{{ID: "i1", Title: "x", MomentTS: 5, MomentSource: "ai"}},
	})
	if placed.any() {
		t.Fatalf("nothing new to save: %+v", placed)
	}
	fr := out["frustrations"].([]moment)
	if fr[0].Source != "matched" || fr[1].Source != "" || fr[1].TS != 0 {
		t.Fatalf("%+v", fr)
	}
	if is := out["issues"].([]moment); is[0].Source != "ai" || is[0].TS != 5 {
		t.Fatalf("%+v", is)
	}
}
