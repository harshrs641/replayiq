// Package masking redacts PII in rrweb event batches before they're stored
// as the "masked" copy of a session. It runs server-side, independent of
// whatever the SDK already blanked in the browser, so:
//
//   - new selectors can be added here (via Config) and apply retroactively
//     to every session ingested from then on, without redeploying the SDK
//     snippet on every customer site, and
//   - a regex-based net catches PII typed into fields nobody tagged at all
//     (a stray SSN in a "notes" textarea, an email pasted into a search box).
//
// The raw, unmasked batch is still stored as-is elsewhere (see
// storage.MinIO's two buckets) - this package only ever produces the masked
// copy, never mutates the original.
package masking

import (
	"regexp"
	"strings"
	"sync"

	"github.com/harshrs641/replayiq/internal/models"
)

// Rule is a single PII pattern: any substring matching Pattern in captured
// text or attribute values is rewritten via Mask in the masked copy.
type Rule struct {
	Name    string
	Pattern *regexp.Regexp
	Mask    func(string) string
}

// Config controls what gets redacted. Classes/AttrNamePatterns mirror the
// SDK's own riq-mask / data-riq-mask / PII_SELECTORS convention so the same
// element can be tagged once and respected both at capture time (SDK blocks
// it before it leaves the browser) and here (catches anything the SDK
// config missed).
type Config struct {
	// Classes are CSS class names that mark an element - and everything
	// inside it - as fully redacted (e.g. "riq-mask").
	Classes []string
	// AttrNamePatterns match against an element's name/id/autocomplete
	// attributes, same intent as the SDK's PII_SELECTORS list.
	AttrNamePatterns []*regexp.Regexp
	// Rules are regex-based PII detectors applied to every text/attribute
	// value as a defense-in-depth net, independent of selectors.
	Rules []Rule
}

// DefaultConfig returns the built-in masking rules plus any extra CSS
// classes an operator wants treated as sensitive (configured via
// MASK_CLASSES).
func DefaultConfig(extraClasses []string) Config {
	classes := append([]string{"riq-mask"}, extraClasses...)
	return Config{
		Classes: classes,
		AttrNamePatterns: []*regexp.Regexp{
			regexp.MustCompile(`(?i)card`),
			regexp.MustCompile(`(?i)cvv`),
			regexp.MustCompile(`(?i)ssn`),
			regexp.MustCompile(`(?i)password`),
			regexp.MustCompile(`(?i)phone`),
			regexp.MustCompile(`(?i)email`),
		},
		Rules: DefaultRules(),
	}
}

// DefaultRules is the built-in regex PII net: email, credit card, SSN, and
// phone number shaped strings, each masked while keeping just enough of the
// original visible to stay useful for debugging (last 4 digits, domain,
// etc.) without exposing the full value.
func DefaultRules() []Rule {
	return []Rule{
		{
			Name: "email",
			// Domain labels must start with a letter, not a digit - without
			// that, this pattern also matches retina image asset filenames
			// like "avatar@2x.png" or "logo@3x.jpg" (a very common web
			// naming convention) as if "2x.png"/"3x.jpg" were an email
			// domain, and would corrupt those URLs in the masked replay.
			Pattern: regexp.MustCompile(`[\w.+-]+@[A-Za-z][\w-]*(?:\.[A-Za-z][\w-]*)*\.[A-Za-z]{2,24}`),
			Mask: func(s string) string {
				at := strings.IndexByte(s, '@')
				if at <= 0 {
					return "•••@•••"
				}
				return s[:1] + strings.Repeat("•", at-1) + s[at:]
			},
		},
		{
			Name:    "credit_card",
			Pattern: regexp.MustCompile(`\b(?:\d[ -]?){13,16}\b`),
			Mask: func(s string) string {
				var digits strings.Builder
				for _, r := range s {
					if r >= '0' && r <= '9' {
						digits.WriteRune(r)
					}
				}
				d := digits.String()
				if len(d) < 4 {
					return "••••"
				}
				return "•••• •••• •••• " + d[len(d)-4:]
			},
		},
		{
			Name:    "ssn",
			Pattern: regexp.MustCompile(`\b\d{3}-\d{2}-\d{4}\b`),
			Mask:    func(string) string { return "•••-••-••••" },
		},
		{
			Name:    "phone",
			Pattern: regexp.MustCompile(`\b(?:\+?\d{1,2}[ .-]?)?\(?\d{3}\)?[ .-]?\d{3}[ .-]?\d{4}\b`),
			Mask: func(s string) string {
				if len(s) <= 2 {
					return strings.Repeat("•", len(s))
				}
				return strings.Repeat("•", len(s)-2) + s[len(s)-2:]
			},
		},
	}
}

// Tracker remembers, per session, which rrweb mirror-tree node ids were
// found inside a sensitive element (matched a Classes/AttrNamePatterns
// rule). rrweb only sends an element's attributes when the node is first
// created (a FullSnapshot, or a mutation's "adds" list) - later updates to
// that same node (a keystroke, a text mutation) carry only its id. Without
// remembering which ids were sensitive once seen, per-keystroke updates to
// a tagged field would slip through unredacted.
//
// State lives in process memory only and resets on restart; the next
// FullSnapshot (rrweb's own checkoutEveryNth, or simply the start of a new
// session) re-establishes it, so any gap is short-lived.
type Tracker struct {
	mu  sync.Mutex
	ids map[string]map[float64]bool
}

func NewTracker() *Tracker {
	return &Tracker{ids: make(map[string]map[float64]bool)}
}

func (t *Tracker) mark(sessionID string, id float64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	set := t.ids[sessionID]
	if set == nil {
		set = make(map[float64]bool)
		t.ids[sessionID] = set
	}
	set[id] = true
}

func (t *Tracker) isSensitive(sessionID string, id float64) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.ids[sessionID][id]
}

// MaskBatch returns a deep copy of batch with PII redacted per cfg, meant to
// be stored as the "masked" view of a session's events. batch itself is
// left untouched so the caller can still persist it unmodified as the raw,
// unmasked view.
func MaskBatch(t *Tracker, batch *models.EventBatch, cfg Config) *models.EventBatch {
	out := *batch

	out.Events = make([]models.RRWebEvent, len(batch.Events))
	for i, e := range batch.Events {
		out.Events[i] = maskEvent(t, batch.SessionID, e, cfg)
	}

	out.CustomEvents = make([]models.CustomEvent, len(batch.CustomEvents))
	for i, c := range batch.CustomEvents {
		if props, ok := maskValue(t, batch.SessionID, c.Properties, cfg, false).(map[string]any); ok {
			c.Properties = props
		}
		out.CustomEvents[i] = c
	}

	return &out
}

// maskEvent masks both the SDK's flat custom-event fields (network/console/
// behavior events don't carry a `data` payload at all - see models.RRWebEvent)
// and native rrweb events' nested Data tree.
func maskEvent(t *Tracker, sessionID string, e models.RRWebEvent, cfg Config) models.RRWebEvent {
	e = maskTextFields(e, cfg)
	if e.Data != nil {
		if data, ok := maskValue(t, sessionID, e.Data, cfg, false).(map[string]any); ok {
			e.Data = data
		}
	}
	return e
}

// maskTextFields masks the SDK's flat free-text fields only.
func maskTextFields(e models.RRWebEvent, cfg Config) models.RRWebEvent {
	e.Message = maskText(e.Message, cfg)
	e.URL = maskText(e.URL, cfg)
	e.Selector = maskText(e.Selector, cfg)
	e.Filename = maskText(e.Filename, cfg)
	e.Stack = maskText(e.Stack, cfg)
	e.Error = maskText(e.Error, cfg)
	return e
}

// MaskTextFields returns a copy of batch with PII redacted in the events'
// free-text fields (message, URL, selector, error details) but each event's
// Data left as is. For device-masked batches (mobile): their pixels were
// masked on the phone, but console/network/error text from the app was not,
// and these sessions keep a single stored copy. Skipping Data avoids running
// the regexes over base64 screenshots.
func MaskTextFields(batch *models.EventBatch, cfg Config) *models.EventBatch {
	out := *batch
	out.Events = make([]models.RRWebEvent, len(batch.Events))
	for i, e := range batch.Events {
		out.Events[i] = maskTextFields(e, cfg)
	}
	return &out
}

// maskValue walks an arbitrary rrweb payload (map[string]any / []any /
// scalars) and returns a redacted deep copy. `sensitive` propagates
// downward once a node is found inside (or was previously marked as) a
// masked element, so every descendant text/value is fully redacted
// regardless of its own attributes.
func maskValue(t *Tracker, sessionID string, v any, cfg Config, sensitive bool) any {
	switch val := v.(type) {
	case map[string]any:
		out := make(map[string]any, len(val))
		nodeSensitive := sensitive || isSensitiveNode(val, cfg)
		if id, ok := nodeID(val); ok {
			if nodeSensitive {
				t.mark(sessionID, id)
			} else if t.isSensitive(sessionID, id) {
				nodeSensitive = true
			}
		}
		for k, sub := range val {
			switch k {
			case "tagName":
				// Structural rrweb field — the element type needed by rrweb-player
				// to call document.createElement(). Redacting it collapses every
				// element in the sensitive subtree into HTMLUnknownElement, making
				// the masked replay appear completely blank.
				out[k] = sub
				continue
			case "textContent", "value", "text":
				if s, ok := sub.(string); ok {
					if nodeSensitive {
						out[k] = redact(s)
					} else {
						out[k] = maskText(s, cfg)
					}
					continue
				}
			}
			out[k] = maskValue(t, sessionID, sub, cfg, nodeSensitive)
		}
		return out
	case []any:
		out := make([]any, len(val))
		for i, sub := range val {
			out[i] = maskValue(t, sessionID, sub, cfg, sensitive)
		}
		return out
	case string:
		if sensitive {
			return redact(val)
		}
		return maskText(val, cfg)
	default:
		return val
	}
}

// nodeID extracts an rrweb mirror-tree node id from a decoded JSON map.
// encoding/json always decodes numbers into float64 for `any` targets.
func nodeID(node map[string]any) (float64, bool) {
	id, ok := node["id"].(float64)
	return id, ok
}

// isSensitiveNode reports whether a decoded rrweb DOM node's own attributes
// (class, data-riq-mask, name/id/autocomplete) match cfg. Only nodes that
// carry attributes at all (snapshot nodes, mutation "adds") can be detected
// this way - see Tracker for how later updates to the same node are caught.
func isSensitiveNode(node map[string]any, cfg Config) bool {
	attrs, _ := node["attributes"].(map[string]any)
	if attrs == nil {
		return false
	}
	if class, ok := attrs["class"].(string); ok {
		for _, c := range cfg.Classes {
			if strings.Contains(class, c) {
				return true
			}
		}
	}
	if _, ok := attrs["data-riq-mask"]; ok {
		return true
	}
	for _, key := range []string{"name", "id", "autocomplete"} {
		s, ok := attrs[key].(string)
		if !ok {
			continue
		}
		for _, p := range cfg.AttrNamePatterns {
			if p.MatchString(s) {
				return true
			}
		}
	}
	return false
}

// redact fully blanks a string, capping the visible length so the redacted
// placeholder doesn't itself leak how long the original value was.
func redact(s string) string {
	if s == "" {
		return s
	}
	n := len([]rune(s))
	if n > 12 {
		n = 12
	}
	return strings.Repeat("•", n)
}

func maskText(s string, cfg Config) string {
	for _, rule := range cfg.Rules {
		s = rule.Pattern.ReplaceAllStringFunc(s, rule.Mask)
	}
	return s
}
