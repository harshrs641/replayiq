package api

import (
	"github.com/harshrs641/replayiq/internal/models"
	"testing"
	"time"
)

func TestLRUCacheEvictsLeastRecentlyUsedBySize(t *testing.T) {
	c := newLRUCache[string](100, time.Hour)
	c.Put("a", "A", 20)
	c.Put("b", "B", 20)
	c.Get("a") // a is now newer than b
	c.Put("c", "C", 20)
	c.Put("d", "D", 20)
	c.Put("e", "E", 25) // over 100: drop the least recently used (b)
	if _, ok := c.Get("b"); ok {
		t.Fatal("b should have been evicted")
	}
	for _, k := range []string{"a", "c", "d", "e"} {
		if _, ok := c.Get(k); !ok {
			t.Fatalf("%s should still be cached", k)
		}
	}
	c.Put("huge", "H", 26) // over a quarter of the cache: not kept
	if _, ok := c.Get("huge"); ok {
		t.Fatal("oversized values must not be cached")
	}
}

func TestLRUCacheExpires(t *testing.T) {
	now := time.Unix(0, 0)
	c := newLRUCache[int](10, time.Minute)
	c.now = func() time.Time { return now }
	c.Put("k", 1, 1)
	now = now.Add(59 * time.Second)
	if v, ok := c.Get("k"); !ok || v != 1 {
		t.Fatal("should be cached before the TTL")
	}
	now = now.Add(2 * time.Second)
	if _, ok := c.Get("k"); ok || c.Len() != 0 {
		t.Fatal("should expire after the TTL")
	}
}

func TestIsFinal(t *testing.T) {
	now := time.Now()
	ended := func(d time.Duration) *models.Session { x := now.Add(-d); return &models.Session{EndedAt: &x} }
	if isFinal(nil, now) || isFinal(&models.Session{}, now) {
		t.Fatal("unknown or unended sessions are not final")
	}
	if isFinal(ended(time.Minute), now) {
		t.Fatal("a session that just ended is still settling")
	}
	if !isFinal(ended(time.Hour), now) {
		t.Fatal("a session that ended an hour ago is final")
	}
}
