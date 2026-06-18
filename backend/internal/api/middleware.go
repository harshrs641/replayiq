package api

import (
	"log/slog"
	"net/http"
	"time"
)

// withMiddleware wraps the router's mux with CORS handling and request
// logging. CORS is the outer layer so preflight OPTIONS requests short
// circuit before timing/logging ever runs.
func (r *router) withMiddleware() http.Handler {
	return withCORS(withLogging(r.mux))
}

// withCORS allows the recording console injected into any site to call the
// API, and answers preflight requests directly.
func withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET,POST,PUT,DELETE,OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type,X-Project-ID,Authorization")
		if req.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, req)
	})
}

// withLogging records the method, path, status, and duration of every
// request that reaches it.
func withLogging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		start := time.Now()
		rw := &responseWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rw, req)
		slog.Info("request", "method", req.Method, "path", req.URL.Path, "status", rw.status, "duration", time.Since(start))
	})
}

// responseWriter captures the status code written by a handler so it can be
// logged once the request completes.
type responseWriter struct {
	http.ResponseWriter
	status int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.status = code
	rw.ResponseWriter.WriteHeader(code)
}
