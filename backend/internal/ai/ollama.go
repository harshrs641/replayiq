package ai

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/harshrs641/replayiq/internal/models"
)

// ─── Ollama Engine ────────────────────────────────────────────────────────────

type OllamaEngine struct {
	endpoint       string
	model          string
	// smallModel is used for short, low-signal sessions (< 30 s, < 20 events,
	// no rage clicks or network errors).  Empty means fall back to model.
	smallModel string
	// largeModel is used for long or high-signal sessions (rage clicks + errors,
	// or duration > 10 min).  Empty means fall back to model.
	largeModel     string
	embeddingModel string
	client         *http.Client
}

func NewOllamaEngine(endpoint, model, embeddingModel string) *OllamaEngine {
	return &OllamaEngine{
		endpoint:       endpoint,
		model:          model,
		embeddingModel: embeddingModel,
		client:         &http.Client{Timeout: 120 * time.Second},
	}
}

// WithModelTiering configures optional small and large model overrides.
// Pass empty strings to leave a tier at the default model.
func (o *OllamaEngine) WithModelTiering(smallModel, largeModel string) *OllamaEngine {
	o.smallModel = smallModel
	o.largeModel = largeModel
	return o
}

// selectModel picks the Ollama model name for a given session based on its
// complexity signals.  Returns o.model when the tier is not configured.
func (o *OllamaEngine) selectModel(session *models.Session, events []models.TokenizedEvent) string {
	hasRageClick := false
	hasNetworkError := false
	for _, e := range events {
		if e.Action == "rage_click" {
			hasRageClick = true
		}
		if e.Action == "network_error" {
			hasNetworkError = true
		}
	}

	isComplex := (hasRageClick && hasNetworkError) || session.DurationMs > 10*60*1000
	isSimple := session.DurationMs < 30*1000 && session.EventCount < 20 && !hasRageClick && !hasNetworkError

	if isComplex && o.largeModel != "" {
		return o.largeModel
	}
	if isSimple && o.smallModel != "" {
		return o.smallModel
	}
	return o.model
}

type ollamaRequest struct {
	Model  string `json:"model"`
	Prompt string `json:"prompt"`
	Stream bool   `json:"stream"`
	Options map[string]any `json:"options,omitempty"`
}

type ollamaResponse struct {
	Response string `json:"response"`
	Done     bool   `json:"done"`
}

// withRetry calls fn up to maxAttempts times, sleeping with exponential
// backoff between attempts.  It stops immediately if ctx is cancelled or if
// fn returns a non-transient (nil) error on the first try.
func withRetry(ctx context.Context, maxAttempts int, fn func() error) error {
	var lastErr error
	backoff := 2 * time.Second
	for attempt := 0; attempt < maxAttempts; attempt++ {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := fn(); err == nil {
			return nil
		} else {
			lastErr = err
		}
		if attempt < maxAttempts-1 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(backoff):
			}
			backoff *= 2
		}
	}
	return lastErr
}

func (o *OllamaEngine) complete(ctx context.Context, model, prompt string) (string, error) {
	body, _ := json.Marshal(ollamaRequest{
		Model:  model,
		Prompt: prompt,
		Stream: false,
		Options: map[string]any{"temperature": 0.3, "num_predict": 600},
	})

	var result ollamaResponse
	err := withRetry(ctx, 3, func() error {
		req, err := http.NewRequestWithContext(ctx, "POST", o.endpoint+"/api/generate", bytes.NewReader(body))
		if err != nil {
			return err
		}
		req.Header.Set("Content-Type", "application/json")

		resp, err := o.client.Do(req)
		if err != nil {
			return fmt.Errorf("ollama request: %w", err)
		}
		defer resp.Body.Close()
		return json.NewDecoder(resp.Body).Decode(&result)
	})
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(result.Response), nil
}

// ─── Session Analysis ─────────────────────────────────────────────────────────

func (o *OllamaEngine) AnalyzeSession(ctx context.Context, session *models.Session, batches []models.EventBatch) (*models.SessionSummary, error) {
	// Build tokenized event list from raw rrweb events
	tokenized := tokenizeEvents(batches)

	model := o.selectModel(session, tokenized)
	prompt := buildAnalysisPrompt(session, tokenized)

	raw, err := o.complete(ctx, model, prompt)
	if err != nil {
		return nil, fmt.Errorf("ollama analyze: %w", err)
	}

	summary, refs, err := parseAnalysisResponse(raw)
	if err != nil {
		// Fallback: basic summary
		summary = &models.SessionSummary{
			Narrative:       raw,
			TokenizedEvents: tokenized,
		}
	}
	summary.TokenizedEvents = tokenized
	groundSummary(summary, refs, tokenized)
	return summary, nil
}

// groundSummary sets when each frustration and issue happened, from the
// model's event citations (indexes into the numbered prompt events) or,
// failing that, by matching the text against the events.
func groundSummary(summary *models.SessionSummary, frustrationRefs []int, tokenized []models.TokenizedEvent) {
	cited := citedEvents(truncateEventsForPrompt(tokenized))
	summary.FrustrationTS = make([]int64, len(summary.Frustrations))
	for i, f := range summary.Frustrations {
		ref := -1
		if i < len(frustrationRefs) {
			ref = frustrationRefs[i]
		}
		summary.FrustrationTS[i] = resolve(ref, cited, f, tokenized)
	}
	for i := range summary.Issues {
		is := &summary.Issues[i]
		is.MomentTS = resolve(eventRef(is.Event), cited, is.Title+". "+is.Description, tokenized)
	}
}

// TokenizeEvents converts raw rrweb event batches into a deduplicated,
// signal-only event list.  Exported so callers outside this package can
// compare fresh tokenization against a stored ai_tokenized value without
// re-running the full analysis pipeline.
// tokenTimeLayout keeps milliseconds: whole seconds made several actions in
// the same second look simultaneous (and sorted them out of order), and a
// finding's jump time could land up to a second early.
const tokenTimeLayout = "2006-01-02T15:04:05.000Z07:00"

func TokenizeEvents(batches []models.EventBatch) []models.TokenizedEvent {
	return tokenizeEvents(batches)
}

func tokenizeEvents(batches []models.EventBatch) []models.TokenizedEvent {
	var events []models.TokenizedEvent

	for _, batch := range batches {
		for _, e := range batch.Events {
			te := models.TokenizedEvent{
				T: time.Unix(0, e.Timestamp*int64(time.Millisecond)).Format(tokenTimeLayout),
			}

			switch {
			case e.Subtype == "rage_click":
				te.Action = "rage_click"
				te.Target = e.Selector
			case e.Subtype == "click":
				te.Action = "click"
				te.Target = e.Selector
			case e.Subtype == "input":
				te.Action = "input"
				te.Target = e.Selector
			case e.Type == 3:
				continue // native rrweb mutation/mousemove noise - "click"/"input" above carry the real signal
			case e.Subtype == "network":
				switch {
				case e.Status >= 400:
					te.Action = "network_error"
					te.Target = e.URL
					te.Value = fmt.Sprintf("HTTP %d", e.Status)
				case e.Status == 0 && e.Error != "":
					// Never got a response (offline, DNS, CORS, timeout).
					te.Action = "network_error"
					te.Target = e.URL
					te.Value = e.Error
				default:
					continue // only log errors
				}
			case e.Subtype == "navigate":
				// Screen changes reported by an app (e.g. Flutter routes).
				te.Action = "navigate"
				te.Target = e.URL
			case e.Subtype == "js_error":
				te.Action = "js_error"
				te.Target = e.Message
			case e.Type == 4: // meta / navigation
				te.Action = "navigate"
				if url, ok := e.Data["href"].(string); ok {
					te.Target = url
				}
			default:
				continue
			}

			if te.Action != "" {
				events = append(events, te)
			}
		}

		// Include custom events
		for _, ce := range batch.CustomEvents {
			events = append(events, models.TokenizedEvent{
				T:      time.Unix(0, ce.Timestamp*int64(time.Millisecond)).Format(tokenTimeLayout),
				Action: "custom:" + ce.Name,
			})
		}
	}

	// Batches are normally already chronological (MinIO keys are
	// zero-padded-length unix-ms timestamps), but sort explicitly so the
	// narrative the LLM builds isn't at the mercy of storage listing order.
	sort.Slice(events, func(i, j int) bool { return events[i].T < events[j].T })

	return dedupeConsecutive(events)
}

// dedupeConsecutive collapses runs of identical action+target entries (e.g.
// one "input" event fires per keystroke on the same field) into one, so the
// LLM sees "typed into #email" once instead of a wall of near-duplicates.
func dedupeConsecutive(events []models.TokenizedEvent) []models.TokenizedEvent {
	if len(events) == 0 {
		return events
	}
	out := events[:1]
	for _, e := range events[1:] {
		last := out[len(out)-1]
		if e.Action == last.Action && e.Target == last.Target {
			continue
		}
		out = append(out, e)
	}
	return out
}

// promptEventWindow keeps the tokenized event list within the model's
// context budget. We preserve the head (early navigation, page load context)
// and the tail (where errors and abandonment happen) and drop the middle.
// 50 head + 100 tail keeps the prompt under ~4 000 tokens for llama3.1:8b.
const (
	promptHeadEvents = 50
	promptTailEvents = 100
	promptMaxEvents  = promptHeadEvents + promptTailEvents
)

func truncateEventsForPrompt(events []models.TokenizedEvent) []models.TokenizedEvent {
	if len(events) <= promptMaxEvents {
		return events
	}
	omitted := len(events) - promptMaxEvents
	head := events[:promptHeadEvents]
	tail := events[len(events)-promptTailEvents:]
	marker := models.TokenizedEvent{
		Action: fmt.Sprintf("... %d events omitted ...", omitted),
	}
	out := make([]models.TokenizedEvent, 0, promptMaxEvents+1)
	out = append(out, head...)
	out = append(out, marker)
	out = append(out, tail...)
	return out
}

func buildAnalysisPrompt(session *models.Session, events []models.TokenizedEvent) string {
	eventsJSON, _ := json.MarshalIndent(numberForPrompt(truncateEventsForPrompt(events)), "", "  ")
	return fmt.Sprintf(`You are an AI session analyst for an enterprise product. Analyze this user session and return a JSON object.

SESSION CONTEXT:
- URL: %s
- Duration: %dms
- User Agent: %s

USER ACTIONS (tokenized; "i" numbers each action):
%s

Return ONLY valid JSON with this exact structure, no markdown, no explanation:
{
  "narrative": "2-3 sentence plain English summary of what the user did and what happened",
  "goal_achieved": true or false,
  "goal_evidence": "one sentence explaining why goal was or was not achieved",
  "frustrations": [{"text": "a frustration moment observed", "event": i of the USER ACTIONS entry where it happens}],
  "key_moments": ["most important events in the session"],
  "tags": ["relevant tags like: form_error, rage_click, payment, abandoned, success, etc"],
  "issues": [
    {
      "type": "bug|ux|error",
      "title": "short issue title",
      "description": "what happened and why it's a problem",
      "severity": "P0|P1|P2|P3",
      "tags": ["issue tags"],
      "event": i of the USER ACTIONS entry where it happens
    }
  ]
}`,
		session.URL,
		session.DurationMs,
		session.UserAgent,
		string(eventsJSON),
	)
}

// parseAnalysisResponse also returns, per frustration, the event index the
// model cited (-1 when it didn't).
func parseAnalysisResponse(raw string) (*models.SessionSummary, []int, error) {
	// Strip any markdown fences
	raw = strings.TrimPrefix(raw, "```json")
	raw = strings.TrimPrefix(raw, "```")
	raw = strings.TrimSuffix(raw, "```")
	raw = strings.TrimSpace(raw)

	// Find JSON object
	start := strings.Index(raw, "{")
	end := strings.LastIndex(raw, "}")
	if start == -1 || end == -1 {
		return nil, nil, fmt.Errorf("no JSON found in response")
	}
	raw = raw[start : end+1]

	var result struct {
		Narrative    string `json:"narrative"`
		GoalAchieved bool   `json:"goal_achieved"`
		GoalEvidence string `json:"goal_evidence"`
		// Both of these are requested as plain string arrays but the model
		// doesn't always comply (frustrations sometimes come back as
		// {timestamp, description}, key_moments as {time, action, target}) -
		// decode each entry loosely so one off-schema field doesn't fail
		// the whole response and discard everything else into the
		// raw-text fallback.
		Frustrations []json.RawMessage      `json:"frustrations"`
		KeyMoments   []json.RawMessage      `json:"key_moments"`
		Tags         []string               `json:"tags"`
		Issues       []models.DetectedIssue `json:"issues"`
	}

	if err := json.Unmarshal([]byte(raw), &result); err != nil {
		return nil, nil, err
	}

	frustrations := make([]string, 0, len(result.Frustrations))
	refs := make([]int, 0, len(result.Frustrations))
	for _, f := range result.Frustrations {
		text, ref := frustrationEntry(f)
		frustrations = append(frustrations, text)
		refs = append(refs, ref)
	}

	keyMoments := make([]string, 0, len(result.KeyMoments))
	for _, km := range result.KeyMoments {
		keyMoments = append(keyMoments, stringifyTextEntry(km, "action", "target"))
	}

	return &models.SessionSummary{
		Narrative:    result.Narrative,
		GoalAchieved: result.GoalAchieved,
		GoalEvidence: result.GoalEvidence,
		Frustrations: frustrations,
		KeyMoments:   keyMoments,
		Tags:         result.Tags,
		Issues:       result.Issues,
	}, refs, nil
}

// frustrationEntry reads one frustration: a plain string (no citation) or
// an object with the text under "text" or "description" and the cited
// event under "event".
func frustrationEntry(raw json.RawMessage) (string, int) {
	var obj map[string]any
	if err := json.Unmarshal(raw, &obj); err == nil {
		for _, k := range []string{"text", "description"} {
			if v, _ := obj[k].(string); v != "" {
				return v, eventRef(obj["event"])
			}
		}
	}
	return stringifyTextEntry(raw, "description"), -1
}

// stringifyTextEntry coerces a loosely-typed array entry (frustrations,
// key_moments) into a readable string whether the model returned a plain
// string or an object. preferredFields are tried in order: a single field
// is returned as-is, two are joined as "a: b". Falls back to the raw JSON
// if none of them are present.
func stringifyTextEntry(raw json.RawMessage, preferredFields ...string) string {
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}

	var obj map[string]any
	if err := json.Unmarshal(raw, &obj); err == nil {
		var parts []string
		for _, field := range preferredFields {
			if v, _ := obj[field].(string); v != "" {
				parts = append(parts, v)
			}
		}
		if len(parts) > 0 {
			return strings.Join(parts, ": ")
		}
	}
	return string(raw)
}

// ─── Embedding for semantic search ───────────────────────────────────────────

type embeddingRequest struct {
	Model  string `json:"model"`
	Prompt string `json:"prompt"`
}

type embeddingResponse struct {
	Embedding []float64 `json:"embedding"`
}

func (o *OllamaEngine) Embed(ctx context.Context, text string) ([]float64, error) {
	body, _ := json.Marshal(embeddingRequest{Model: o.embeddingModel, Prompt: text})

	var result embeddingResponse
	err := withRetry(ctx, 3, func() error {
		req, err := http.NewRequestWithContext(ctx, "POST", o.endpoint+"/api/embeddings", bytes.NewReader(body))
		if err != nil {
			return err
		}
		req.Header.Set("Content-Type", "application/json")

		resp, err := o.client.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		return json.NewDecoder(resp.Body).Decode(&result)
	})
	if err != nil {
		return nil, err
	}
	return result.Embedding, nil
}
