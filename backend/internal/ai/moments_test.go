package ai

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/harshrs641/replayiq/internal/models"
)

var base = time.Date(2026, 11, 17, 10, 0, 0, 0, time.UTC)

func tok(sec int, action, target, value string) models.TokenizedEvent {
	return models.TokenizedEvent{T: base.Add(time.Duration(sec) * time.Second).Format(time.RFC3339), Action: action, Target: target, Value: value}
}

func ms(sec int) int64 { return base.Add(time.Duration(sec) * time.Second).UnixMilli() }

var session = []models.TokenizedEvent{
	tok(0, "navigate", "app://flutter", ""),
	tok(12, "click", `input`, ""),
	tok(18, "click", `button:"Pay now"`, ""),
	tok(19, "rage_click", `button:"Pay now"`, ""),
	tok(25, "network_error", "https://api.test/checkout/submit", "HTTP 500"),
	tok(30, "js_error", "TypeError: cannot read total of undefined", ""),
	tok(40, "click", `button:"Order summary"`, ""),
}

func TestGroundText(t *testing.T) {
	for _, c := range []struct {
		text string
		want int64
	}{
		{"User rage-clicked the Pay now button with no response", ms(19)},
		{`Tapped "Pay now" repeatedly`, ms(19)},
		{"Checkout submit returned a 500 error", ms(25)},
		{"Request to /checkout/submit failed", ms(25)},
		{"A TypeError crashed the page: cannot read total of undefined", ms(30)},
		{`Opened "Order summary" after failing to pay`, ms(40)},
		{"Form errors while filling in the departure date", 0}, // not the failed request
		{"Page failed to load prices: server error", ms(25)},
		{"User seemed confused", 0},
		{"clicked a button", 0}, // kind alone is too weak
		{"", 0},
	} {
		if got := GroundText(c.text, session); got != c.want {
			t.Errorf("%q: got %d want %d", c.text, got, c.want)
		}
	}
}

func TestParseCitationsAndGround(t *testing.T) {
	raw := `{"narrative":"n","goal_achieved":false,
	  "frustrations":[{"text":"Rage-tapped Pay now","event":3},
	                  "Checkout returned HTTP 500",
	                  {"description":"cited out of range","event":99},
	                  {"text":"cited as string","event":"5"}],
	  "issues":[{"type":"bug","title":"Pay now unresponsive","description":"d","severity":"P1","tags":[],"event":2},
	            {"type":"bug","title":"Checkout submit returns 500","description":"d","severity":"P0","tags":[]}]}`
	s, refs, err := parseAnalysisResponse(raw)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(s.Frustrations, "|"); got != "Rage-tapped Pay now|Checkout returned HTTP 500|cited out of range|cited as string" {
		t.Fatalf("frustration texts: %s", got)
	}
	if want := []int{3, -1, 99, 5}; len(refs) != 4 || refs[0] != want[0] || refs[1] != want[1] || refs[2] != want[2] || refs[3] != want[3] {
		t.Fatalf("refs %v", refs)
	}
	groundSummary(s, refs, session)
	want := []int64{
		ms(19), // cited event 3
		ms(25), // no citation: matched by text
		0,      // bad citation, and the text matches nothing
		ms(30), // "5" as a string
	}
	for i, w := range want {
		if s.FrustrationTS[i] != w {
			t.Errorf("frustration %d: got %d want %d", i, s.FrustrationTS[i], w)
		}
	}
	if s.Issues[0].MomentTS != ms(18) || s.Issues[1].MomentTS != ms(25) {
		t.Errorf("issue moments %d %d", s.Issues[0].MomentTS, s.Issues[1].MomentTS)
	}
}

func TestPromptNumbersEventsSkippingOmittedMarker(t *testing.T) {
	var many []models.TokenizedEvent
	for i := 0; i < promptMaxEvents+20; i++ {
		many = append(many, tok(i, "click", "x", ""))
	}
	numbered := numberForPrompt(truncateEventsForPrompt(many))
	b, _ := json.Marshal(numbered)
	if !strings.Contains(string(b), `"i":149`) || strings.Contains(string(b), `"i":150`) {
		t.Fatal("expected indexes 0..149 over the kept events")
	}
	cited := citedEvents(truncateEventsForPrompt(many))
	if len(cited) != promptMaxEvents || cited[promptHeadEvents].T != many[len(many)-promptTailEvents].T {
		t.Fatal("citation index must map to the event shown with that i, across the omitted marker")
	}
}

func TestTokenizeNavigateAndFailedRequests(t *testing.T) {
	got := tokenizeEvents([]models.EventBatch{{Events: []models.RRWebEvent{
		{Type: 5, Subtype: "navigate", URL: "app://flutter/order-summary", Timestamp: 1000},
		{Type: 5, Subtype: "network", URL: "https://api.test/pay", Status: 0, Error: "SocketException: Failed host lookup", Timestamp: 2000},
		{Type: 5, Subtype: "network", URL: "https://api.test/ok", Status: 0, Timestamp: 3000}, // no error text: skip
		{Type: 5, Subtype: "network", URL: "https://api.test/ok", Status: 200, Timestamp: 4000},
	}}})
	if len(got) != 2 || got[0].Action != "navigate" || got[0].Target != "app://flutter/order-summary" ||
		got[1].Action != "network_error" || got[1].Value != "SocketException: Failed host lookup" {
		t.Fatalf("%+v", got)
	}
}

func TestTokenizeKeepsMillisecondOrder(t *testing.T) {
	got := tokenizeEvents([]models.EventBatch{{Events: []models.RRWebEvent{
		{Type: 5, Subtype: "js_error", Message: "boom", Timestamp: 1794916418700},
		{Type: 5, Subtype: "click", Selector: "button#apply", Timestamp: 1794916418200},
	}}})
	if len(got) != 2 || got[0].Action != "click" || got[1].Action != "js_error" {
		t.Fatalf("same-second events must keep their order: %+v", got)
	}
	if TokenTimeMs(got[0].T) != 1794916418200 {
		t.Fatalf("milliseconds lost: %s", got[0].T)
	}
}
