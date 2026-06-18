package api

import "sync"

// embedCache is a fixed-capacity in-memory cache for embedding vectors.
// When the cache is full it clears itself entirely — simple and allocation-
// free compared to a full LRU, and sufficient for search query workloads
// where a small hot set of queries repeats frequently.
type embedCache struct {
	mu      sync.RWMutex
	entries map[string][]float64
	maxSize int
}

func newEmbedCache(maxSize int) *embedCache {
	return &embedCache{
		entries: make(map[string][]float64, maxSize),
		maxSize: maxSize,
	}
}

func (c *embedCache) get(key string) ([]float64, bool) {
	c.mu.RLock()
	v, ok := c.entries[key]
	c.mu.RUnlock()
	return v, ok
}

func (c *embedCache) set(key string, vec []float64) {
	c.mu.Lock()
	if len(c.entries) >= c.maxSize {
		c.entries = make(map[string][]float64, c.maxSize)
	}
	c.entries[key] = vec
	c.mu.Unlock()
}
