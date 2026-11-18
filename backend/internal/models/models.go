package models

import "time"

// ─── Session ──────────────────────────────────────────────────────────────────

type Session struct {
	ID          string            `json:"session_id" db:"id"`
	ProjectID   string            `json:"project_id" db:"project_id"`
	UserID      string            `json:"user_id" db:"user_id"`
	URL         string            `json:"url" db:"url"`
	UserAgent   string            `json:"user_agent" db:"user_agent"`
	ScreenWidth int               `json:"screen_width" db:"screen_width"`
	ScreenHeight int              `json:"screen_height" db:"screen_height"`
	SDKVersion  string            `json:"sdk_version" db:"sdk_version"`
	Metadata    map[string]any    `json:"metadata" db:"metadata"`
	StartedAt   time.Time         `json:"started_at" db:"started_at"`
	EndedAt     *time.Time        `json:"ended_at,omitempty" db:"ended_at"`
	DurationMs  int64             `json:"duration_ms" db:"duration_ms"`
	EventCount  int               `json:"event_count" db:"event_count"`
	Tags        []string          `json:"tags" db:"tags"`
	// AI-enriched fields
	AISummary      string    `json:"ai_summary,omitempty" db:"ai_summary"`
	AITokenized    string    `json:"ai_tokenized,omitempty" db:"ai_tokenized"`
	AITags         []string  `json:"ai_tags,omitempty" db:"ai_tags"`
	AIGoalAchieved *bool     `json:"ai_goal_achieved,omitempty" db:"ai_goal_achieved"`
	AIFrustrations []string  `json:"ai_frustrations,omitempty" db:"ai_frustrations"`
	// AIFrustrationTS[i] is when AIFrustrations[i] happened (unix ms, 0 =
	// unknown); lets the dashboard jump the replay to it.
	AIFrustrationTS []int64 `json:"ai_frustration_ts,omitempty" db:"ai_frustration_ts"`
	AIProcessedAt  *time.Time `json:"ai_processed_at,omitempty" db:"ai_processed_at"`
	// AIStatus tracks pipeline progress: pending | queued | analyzing |
	// embedding | complete | failed.
	AIStatus string `json:"ai_status" db:"ai_status"`
	AIError  string `json:"ai_error,omitempty" db:"ai_error"`
	// Storage
	StoragePath string `json:"storage_path" db:"storage_path"`
	CreatedAt   time.Time `json:"created_at" db:"created_at"`
	// Populated only by semantic search (cosine similarity to the query, 0-1)
	SimilarityScore float64 `json:"similarity_score,omitempty" db:"-"`
}

// ─── Event Batch ──────────────────────────────────────────────────────────────

type EventBatch struct {
	SessionID    string         `json:"session_id"`
	ProjectID    string         `json:"project_id"`
	Events       []RRWebEvent   `json:"events"`
	CustomEvents []CustomEvent  `json:"custom_events"`
	FlushedAt    time.Time      `json:"flushed_at"`
	// DeviceMasked: the recorder already masked this batch on the device
	// (mobile screenshots are masked as pixels before upload). Server-side
	// masking only redacts DOM text and attributes, so no masked copy is
	// stored and replays serve this copy as the masked view.
	DeviceMasked bool `json:"device_masked,omitempty"`
}

type RRWebEvent struct {
	Type      int            `json:"type"`
	Data      map[string]any `json:"data"`
	Timestamp int64          `json:"timestamp"`
	// enriched
	Subtype  string `json:"subtype,omitempty"`
	Level    string `json:"level,omitempty"`
	Message  string `json:"message,omitempty"`
	URL      string `json:"url,omitempty"`
	Status   int    `json:"status,omitempty"`
	Method   string `json:"method,omitempty"`
	Duration int64  `json:"duration,omitempty"`
	Selector string `json:"selector,omitempty"` // target element for behavior events (e.g. rage_click)
	// Error details (js_error) and failure reason (network status 0).
	Filename string `json:"filename,omitempty"`
	Lineno   int    `json:"lineno,omitempty"`
	Colno    int    `json:"colno,omitempty"`
	Stack    string `json:"stack,omitempty"`
	Error    string `json:"error,omitempty"`
}

type CustomEvent struct {
	Name       string         `json:"name"`
	Properties map[string]any `json:"properties"`
	Timestamp  int64          `json:"timestamp"`
}

// ─── AI Issue ─────────────────────────────────────────────────────────────────

type AIIssue struct {
	ID          string    `json:"id" db:"id"`
	SessionID   string    `json:"session_id" db:"session_id"`
	ProjectID   string    `json:"project_id" db:"project_id"`
	Type        string    `json:"type" db:"type"` // bug, ux, error
	Title       string    `json:"title" db:"title"`
	Description string    `json:"description" db:"description"`
	Severity    string    `json:"severity" db:"severity"` // P0, P1, P2, P3
	Tags        []string  `json:"tags" db:"tags"`
	JiraKey     string    `json:"jira_key,omitempty" db:"jira_key"`
	JiraURL     string    `json:"jira_url,omitempty" db:"jira_url"`
	// MomentTS: when in the session the issue happened (unix ms, 0 = unknown).
	MomentTS int64 `json:"moment_ts,omitempty" db:"moment_ts"`
	CreatedAt   time.Time `json:"created_at" db:"created_at"`
}

// ─── Jira ─────────────────────────────────────────────────────────────────────

type JiraIssueRequest struct {
	SessionID   string `json:"session_id"`
	IssueID     string `json:"issue_id"`
	Summary     string `json:"summary"`
	Description string `json:"description"`
	IssueType   string `json:"issue_type"` // Bug, Task, Story
	Priority    string `json:"priority"`   // Highest, High, Medium, Low
}

type JiraIssueResponse struct {
	Key  string `json:"key"`
	ID   string `json:"id"`
	Self string `json:"self"`
	URL  string `json:"url"`
}

// ─── Session Summary (AI-layer output) ───────────────────────────────────────

type SessionSummary struct {
	// Token-efficient summary (~hundreds of tokens)
	Narrative      string   `json:"narrative"`
	GoalAchieved   bool     `json:"goal_achieved"`
	GoalEvidence   string   `json:"goal_evidence"`
	Frustrations   []string `json:"frustrations"`
	// FrustrationTS[i]: when Frustrations[i] happened (unix ms, 0 = unknown).
	FrustrationTS []int64 `json:"frustration_ts,omitempty"`
	KeyMoments     []string `json:"key_moments"`
	Tags           []string `json:"tags"`
	// Tokenized events (~8KB)
	TokenizedEvents []TokenizedEvent `json:"tokenized_events"`
	// Issues identified
	Issues []DetectedIssue `json:"issues"`
}

type TokenizedEvent struct {
	T       string `json:"t"`        // timestamp ISO
	Action  string `json:"action"`   // click, input, navigate, error, network
	Target  string `json:"target"`   // selector or URL
	Value   string `json:"value,omitempty"`
	Context string `json:"context,omitempty"`
}

type DetectedIssue struct {
	Type        string `json:"type"`
	Title       string `json:"title"`
	Description string `json:"description"`
	Severity    string `json:"severity"`
	Tags        []string `json:"tags"`
	// Event: index of the tokenized event the model cites (number or
	// numeric string; may be missing). Resolved into MomentTS.
	Event    any   `json:"event,omitempty"`
	MomentTS int64 `json:"moment_ts,omitempty"`
}
