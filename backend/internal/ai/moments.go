package ai

// Grounding AI findings (frustrations, issues) to a moment in the session,
// so the dashboard can jump the replay straight to it.
//
// The prompt numbers every tokenized event ("i") and asks the model to cite
// the one each finding is about. Small local models don't always comply, so
// any finding without a valid citation is matched against the events
// deterministically instead (GroundText).

import (
	"encoding/json"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/harshrs641/replayiq/internal/models"
)

// promptEvent is a tokenized event as shown to the model, with the index it
// cites findings by.
type promptEvent struct {
	I int `json:"i"`
	models.TokenizedEvent
}

func numberForPrompt(events []models.TokenizedEvent) []any {
	out := make([]any, 0, len(events))
	n := 0
	for _, e := range events {
		if e.T == "" { // the "... N events omitted ..." marker
			out = append(out, e)
			continue
		}
		out = append(out, promptEvent{I: n, TokenizedEvent: e})
		n++
	}
	return out
}

// citedEvents returns the events the model can cite, in index order.
func citedEvents(events []models.TokenizedEvent) []models.TokenizedEvent {
	var out []models.TokenizedEvent
	for _, e := range events {
		if e.T != "" {
			out = append(out, e)
		}
	}
	return out
}

// eventRef reads a model's event citation: a number, or a numeric string.
// Returns -1 when absent or unusable.
func eventRef(v any) int {
	switch x := v.(type) {
	case float64:
		if x >= 0 && x == float64(int(x)) {
			return int(x)
		}
	case string:
		if n, err := strconv.Atoi(strings.TrimSpace(x)); err == nil && n >= 0 {
			return n
		}
	case json.Number:
		if n, err := strconv.Atoi(x.String()); err == nil && n >= 0 {
			return n
		}
	}
	return -1
}

// TokenTimeMs parses a tokenized event's timestamp to unix ms (0 if invalid).
func TokenTimeMs(t string) int64 {
	ts, err := time.Parse(time.RFC3339Nano, t)
	if err != nil {
		return 0
	}
	return ts.UnixMilli()
}

// resolve turns a citation into a timestamp, falling back to GroundText.
func resolve(ref int, cited []models.TokenizedEvent, text string, all []models.TokenizedEvent) int64 {
	if ref >= 0 && ref < len(cited) {
		if ms := TokenTimeMs(cited[ref].T); ms > 0 {
			return ms
		}
	}
	return GroundText(text, all)
}

var quotedRe = regexp.MustCompile(`["'“”‘’]([^"'“”‘’]{2,60})["'“”‘’]`)
var statusRe = regexp.MustCompile(`\b([45]\d\d)\b`)

// GroundText picks the session event a finding most likely describes and
// returns its time (unix ms), or 0 when nothing matches. Scoring is simple
// and explainable: the event kind the text names (rage click, error, failed
// request, navigation), plus overlap between the event's target (selector,
// URL, message) and the text. Ties go to the earliest event, which is where
// a replay should start to show the lead-up.
func GroundText(text string, events []models.TokenizedEvent) int64 {
	lt := strings.ToLower(text)
	if lt == "" {
		return 0
	}
	mentions := func(words ...string) bool {
		for _, w := range words {
			if strings.Contains(lt, w) {
				return true
			}
		}
		return false
	}
	var quoted []string
	for _, m := range quotedRe.FindAllStringSubmatch(text, -1) {
		quoted = append(quoted, strings.ToLower(strings.TrimSpace(m[1])))
	}
	statuses := statusRe.FindAllString(text, -1)
	aboutForm := mentions("form", "validation", "field", "input")
	textWords := wordSet(lt)

	best, bestScore := int64(0), 0
	for _, e := range events {
		ms := TokenTimeMs(e.T)
		if ms == 0 {
			continue
		}
		target := strings.ToLower(e.Target)
		score := 0
		switch e.Action {
		case "rage_click":
			if mentions("rage", "repeated", "multiple times", "several times", "frantic") {
				score += 4
			}
		case "js_error":
			switch {
			case mentions("exception", "crash", "javascript", "script", "typeerror", "broke"):
				score += 3
			case mentions("error", "failed"):
				// "Form errors" are usually validation messages, not exceptions.
				if aboutForm {
					score++
				} else {
					score += 3
				}
			}
		case "network_error":
			// "error" alone also describes form and JS errors.
			if mentions("network", "request", "api", "server", "timeout", "http", "fetch", "load", "connection", "offline") {
				score += 3
			} else if mentions("fail", "error") {
				score++
			}
			for _, s := range statuses {
				if strings.Contains(e.Value, s) {
					score += 3
				}
			}
		case "navigate":
			if mentions("navigat", "went to", "visited", "opened", "landed", "page") {
				score++
			}
		case "click", "input":
			if mentions("click", "tap", "press", "typed", "entered", "input", "field", "button") {
				score++
			}
		}
		if target != "" {
			for _, q := range quoted {
				if strings.Contains(target, q) {
					score += 4
				}
			}
			// The finding quotes the target itself (selector, path, message).
			if len(target) >= 4 && strings.Contains(lt, target) {
				score += 3
			} else if p := lastPathPart(target); len(p) >= 4 && strings.Contains(lt, p) {
				score += 2
			}
			// Paraphrases: shared distinctive words ("cannot read total").
			score += min(sharedWords(textWords, target), 4)
		}
		if score > bestScore {
			best, bestScore = ms, score
		}
	}
	// A bare kind match ("clicked a button") is too weak to point anywhere.
	if bestScore < 3 {
		return 0
	}
	return best
}

var wordRe = regexp.MustCompile(`[a-z0-9]{4,}`)

// Words too common in findings and selectors to say which event is meant.
var stopWords = map[string]bool{
	"user": true, "users": true, "button": true, "click": true, "clicked": true,
	"page": true, "with": true, "from": true, "that": true, "this": true,
	"input": true, "error": true, "after": true, "when": true, "then": true,
	"https": true, "http": true, "into": true, "were": true, "have": true,
}

func wordSet(s string) map[string]bool {
	out := map[string]bool{}
	for _, w := range wordRe.FindAllString(s, -1) {
		if !stopWords[w] {
			out[w] = true
		}
	}
	return out
}

// sharedWords counts distinct words of target that also occur in the text.
func sharedWords(textWords map[string]bool, target string) int {
	n := 0
	for w := range wordSet(target) {
		if textWords[w] {
			n++
		}
	}
	return n
}

// lastPathPart: "https://x.test/api/validate-card?x=1" -> "validate-card".
func lastPathPart(s string) string {
	if i := strings.IndexAny(s, "?#"); i >= 0 {
		s = s[:i]
	}
	s = strings.TrimRight(s, "/")
	if i := strings.LastIndex(s, "/"); i >= 0 {
		s = s[i+1:]
	}
	return s
}
