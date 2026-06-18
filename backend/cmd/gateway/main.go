// Command gateway is a lightweight reverse proxy that routes traffic between
// the ingest service and the query service based on HTTP method and path,
// exposing a single public endpoint on :8080 (GATEWAY_PORT to override).
//
// Routing rules:
//   POST /api/v1/sessions          → ingest (create session)
//   POST /api/v1/sessions/{id}/end → ingest
//   POST /api/v1/sessions/{id}/analyze → ingest
//   POST /api/v1/events            → ingest
//   everything else                → query  (GETs, Jira POSTs, health, SDK)
//
// This keeps the public API surface identical to the previous monolith so
// the dashboard and SDK require no changes.
package main

import (
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))

	ingestURL := mustParseURL(getEnv("INGEST_URL", "http://localhost:8081"))
	queryURL := mustParseURL(getEnv("QUERY_URL", "http://localhost:8082"))
	port := getEnv("GATEWAY_PORT", "8080")

	ingestProxy := httputil.NewSingleHostReverseProxy(ingestURL)
	queryProxy := httputil.NewSingleHostReverseProxy(queryURL)

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if isIngestPath(r) {
			ingestProxy.ServeHTTP(w, r)
		} else {
			queryProxy.ServeHTTP(w, r)
		}
	})

	slog.Info("gateway starting",
		"port", port,
		"ingest", ingestURL.Host,
		"query", queryURL.Host,
	)
	if err := http.ListenAndServe(fmt.Sprintf(":%s", port), nil); err != nil {
		slog.Error("gateway error", "error", err)
		os.Exit(1)
	}
}

// isIngestPath returns true for write endpoints that belong to the ingest service.
func isIngestPath(r *http.Request) bool {
	if r.Method != http.MethodPost {
		return false
	}
	p := r.URL.Path
	// POST /api/v1/events
	if p == "/api/v1/events" {
		return true
	}
	// POST /api/v1/sessions  (create)
	if p == "/api/v1/sessions" {
		return true
	}
	// POST /api/v1/sessions/{id}/end  or  /api/v1/sessions/{id}/analyze
	if strings.HasPrefix(p, "/api/v1/sessions/") {
		rest := strings.TrimPrefix(p, "/api/v1/sessions/")
		parts := strings.SplitN(rest, "/", 2)
		if len(parts) == 2 && (parts[1] == "end" || parts[1] == "analyze") {
			return true
		}
	}
	return false
}

func mustParseURL(raw string) *url.URL {
	u, err := url.Parse(raw)
	if err != nil {
		slog.Error("invalid URL", "url", raw, "error", err)
		os.Exit(1)
	}
	return u
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
