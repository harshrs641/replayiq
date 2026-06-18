package api

import (
	"net/http"
	"sync"
	"time"
)

// eventRateLimiter enforces a per-project burst cap on POST /api/v1/events.
// It uses a simple token-bucket: each project gets a bucket that refills at
// refillRate tokens/second up to burstCap.  A request costs one token; if
// the bucket is empty the request is rejected with 429.
//
// The limiter is intentionally lightweight: it uses a sync.Map so hot paths
// do not contend on a global mutex, and it never blocks the caller.
type eventRateLimiter struct {
	refillRate float64 // tokens added per second
	burstCap   float64 // max tokens in bucket
	buckets    sync.Map
}

type tokenBucket struct {
	mu       sync.Mutex
	tokens   float64
	lastSeen time.Time
}

func newEventRateLimiter(refillRate, burstCap float64) *eventRateLimiter {
	return &eventRateLimiter{refillRate: refillRate, burstCap: burstCap}
}

// allow returns true if projectID has a token available.
func (l *eventRateLimiter) allow(projectID string) bool {
	v, _ := l.buckets.LoadOrStore(projectID, &tokenBucket{
		tokens:   l.burstCap,
		lastSeen: time.Now(),
	})
	b := v.(*tokenBucket)

	b.mu.Lock()
	defer b.mu.Unlock()

	now := time.Now()
	elapsed := now.Sub(b.lastSeen).Seconds()
	b.lastSeen = now
	b.tokens += elapsed * l.refillRate
	if b.tokens > l.burstCap {
		b.tokens = l.burstCap
	}
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// eventRateLimitMiddleware wraps h and rejects POST requests that exceed the
// per-project rate limit with HTTP 429.  The project_id is read from the
// X-Project-ID header (set by the SDK) or falls back to the client IP so
// unauthenticated traffic is still bounded.
func (r *router) eventRateLimitMiddleware(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		key := req.Header.Get("X-Project-ID")
		if key == "" {
			key = req.RemoteAddr
		}
		if !r.eventLimiter.allow(key) {
			writeError(w, http.StatusTooManyRequests, "rate limit exceeded")
			return
		}
		h(w, req)
	}
}
