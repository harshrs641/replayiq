// Package api implements ReplayIQ's HTTP API: session ingestion, AI-driven
// analysis, semantic search, and Jira integration.
package api

import (
	"net/http"

	"github.com/harshrs641/replayiq/internal/ai"
	"github.com/harshrs641/replayiq/internal/jira"
	"github.com/harshrs641/replayiq/internal/masking"
	"github.com/harshrs641/replayiq/internal/pipeline"
	"github.com/harshrs641/replayiq/internal/storage"
)

// Producer is the interface the ingest handlers use to publish events to the
// message queue.  Keeping it as an interface (rather than *kafka.Producer
// directly) lets handlers be tested without a running Kafka cluster.
// A nil Producer means monolith mode: the handler processes the event
// in-process rather than publishing it.
type Producer interface {
	Publish(topic, key string, value any) error
}

type JiraConfig struct {
	BaseURL    string
	Email      string
	APIToken   string
	ProjectKey string
}

// defaultAnalysisConcurrency is the number of Ollama analysis jobs that may
// run at the same time.  Ollama processes requests serially on a single GPU
// thread, so values above 1 only help when multiple GPU workers are
// available (e.g. Ollama 0.5+ with --parallel).  Set ANALYSIS_CONCURRENCY
// in the environment to override.
const defaultAnalysisConcurrency = 4

type RouterConfig struct {
	DB    *storage.Postgres
	MinIO *storage.MinIO
	AI    *ai.OllamaEngine
	// Producer, when non-nil, enables decoupled (Kafka) mode: write handlers
	// publish events to the queue instead of processing them inline.
	// Set for the ingest service; leave nil for the monolith or query service.
	Producer Producer
	// Analyzer runs the AI analysis pipeline.  Required in monolith mode
	// (Producer == nil) so the router can run analysis inline.  Unused when
	// Producer != nil (the processor service handles analysis).
	Analyzer    *pipeline.Analyzer
	SDKPath     string
	JiraConfig  JiraConfig
	Masking     masking.Config
	MaskTracker *masking.Tracker
	// AnalysisConcurrency caps simultaneous Ollama analysis jobs (monolith
	// mode only).  Zero uses defaultAnalysisConcurrency.
	AnalysisConcurrency int
}

type router struct {
	cfg        RouterConfig
	jiraClient *jira.Client
	mux        *http.ServeMux
	// queryEmbedCache caches embeddings for search query strings so repeated
	// searches for the same term skip the Ollama round-trip (~300 ms saved).
	queryEmbedCache *embedCache
	// eventLimiter enforces per-project burst limits on POST /api/v1/events.
	eventLimiter *eventRateLimiter
}

func newBaseRouter(cfg RouterConfig) *router {
	return &router{
		cfg: cfg,
		jiraClient: jira.NewClient(jira.Config{
			BaseURL:    cfg.JiraConfig.BaseURL,
			Email:      cfg.JiraConfig.Email,
			APIToken:   cfg.JiraConfig.APIToken,
			ProjectKey: cfg.JiraConfig.ProjectKey,
		}),
		mux:             http.NewServeMux(),
		queryEmbedCache: newEmbedCache(1000),
		eventLimiter:    newEventRateLimiter(20, 60),
	}
}

// NewRouter creates a full monolith router with all endpoints.  Used by
// cmd/server (the legacy all-in-one service).
func NewRouter(cfg RouterConfig) http.Handler {
	r := newBaseRouter(cfg)
	r.ingestRoutes()
	r.queryRoutes()
	return r.withMiddleware()
}

// NewIngestRouter creates a router that serves only the write/ingest endpoints.
// Used by cmd/ingest.  Requires cfg.Producer to be set.
func NewIngestRouter(cfg RouterConfig) http.Handler {
	r := newBaseRouter(cfg)
	r.ingestRoutes()
	return r.withMiddleware()
}

// NewQueryRouter creates a router that serves only the read/query endpoints.
// Used by cmd/query.
func NewQueryRouter(cfg RouterConfig) http.Handler {
	r := newBaseRouter(cfg)
	r.queryRoutes()
	return r.withMiddleware()
}

// ingestRoutes registers the write endpoints (session lifecycle + event ingest).
func (r *router) ingestRoutes() {
	r.mux.HandleFunc("/api/v1/sessions", r.handleSessions)
	r.mux.HandleFunc("/api/v1/sessions/", r.handleSessionByID)
	r.mux.HandleFunc("/api/v1/events", r.eventRateLimitMiddleware(r.handleEvents))
}

// queryRoutes registers the read endpoints (session queries, replay, search,
// issues, Jira, health, and SDK file serving).
func (r *router) queryRoutes() {
	r.mux.Handle("/sdk/", http.StripPrefix("/sdk/", http.FileServer(http.Dir(r.cfg.SDKPath))))

	for _, rt := range []struct {
		pattern string
		handler http.HandlerFunc
	}{
		{"/health", r.handleHealth},
		// Exact match for search — takes priority over the subtree pattern below.
		{"/api/v1/sessions/search", r.handleSessionSearch},
		{"/api/v1/sessions", r.handleSessions},
		{"/api/v1/sessions/", r.handleSessionByID},
		{"/api/v1/issues", r.handleIssues},
		{"/api/v1/jira/issues", r.handleJiraCreateIssue},
		{"/api/v1/jira/webhook", r.handleJiraWebhook},
	} {
		r.mux.HandleFunc(rt.pattern, rt.handler)
	}
}

func (r *router) handleHealth(w http.ResponseWriter, req *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "version": "1.0.0"})
}
