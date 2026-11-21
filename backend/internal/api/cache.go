package api

import (
	"container/list"
	"sync"
	"time"
)

// lruCache is a small size-bounded, expiring LRU used for replay data of
// finished sessions (which no longer change). Entries cost `size` units
// (bytes for response bodies, 1 for small structs) against maxSize.
type lruCache[V any] struct {
	mu      sync.Mutex
	maxSize int64
	ttl     time.Duration
	now     func() time.Time
	size    int64
	order   *list.List // front = most recently used
	items   map[string]*list.Element
}

type lruEntry[V any] struct {
	key     string
	val     V
	size    int64
	expires time.Time
}

func newLRUCache[V any](maxSize int64, ttl time.Duration) *lruCache[V] {
	return &lruCache[V]{maxSize: maxSize, ttl: ttl, now: time.Now,
		order: list.New(), items: map[string]*list.Element{}}
}

func (c *lruCache[V]) Get(key string) (V, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	var zero V
	el, ok := c.items[key]
	if !ok {
		return zero, false
	}
	e := el.Value.(*lruEntry[V])
	if c.ttl > 0 && c.now().After(e.expires) {
		c.remove(el)
		return zero, false
	}
	c.order.MoveToFront(el)
	return e.val, true
}

// Put stores val; values larger than a quarter of the cache are not kept
// (one huge session would otherwise evict everything else).
func (c *lruCache[V]) Put(key string, val V, size int64) {
	if size > c.maxSize/4 {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if el, ok := c.items[key]; ok {
		c.remove(el)
	}
	el := c.order.PushFront(&lruEntry[V]{key: key, val: val, size: size, expires: c.now().Add(c.ttl)})
	c.items[key] = el
	c.size += size
	for c.size > c.maxSize {
		c.remove(c.order.Back())
	}
}

func (c *lruCache[V]) Len() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.items)
}

func (c *lruCache[V]) remove(el *list.Element) {
	e := el.Value.(*lruEntry[V])
	c.order.Remove(el)
	delete(c.items, e.key)
	c.size -= e.size
}
