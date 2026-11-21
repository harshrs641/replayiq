package pipeline

import (
	"context"
	"errors"
	"sort"
	"testing"
	"time"
)

type fakeSession struct {
	project string
	created time.Time
}

type fakeRetentionStore struct {
	sessions      map[string]fakeSession
	objects       map[string]bool
	failObjectsOf map[string]bool
}

func (f *fakeRetentionStore) ExpiredSessionIDs(_ context.Context, r RetentionRule, limit int) ([]string, error) {
	var ids []string
	for id, s := range f.sessions {
		except := false
		for _, e := range r.Except {
			except = except || e == s.project
		}
		match := (r.Default && !except) || (!r.Default && s.project == r.Project)
		if match && s.created.Before(r.Cutoff) {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	if len(ids) > limit {
		ids = ids[:limit]
	}
	return ids, nil
}

func (f *fakeRetentionStore) DeleteSessionObjects(_ context.Context, id string) error {
	if f.failObjectsOf[id] {
		return errors.New("storage down")
	}
	delete(f.objects, id)
	return nil
}

func (f *fakeRetentionStore) DeleteSessions(_ context.Context, ids []string) (int64, error) {
	for _, id := range ids {
		delete(f.sessions, id)
	}
	return int64(len(ids)), nil
}

func TestParseRetention(t *testing.T) {
	p, err := ParseRetention(90, " acme=365, demo=7 ,keep=0")
	if err != nil || p.DefaultDays != 90 || p.Projects["acme"] != 365 || p.Projects["demo"] != 7 || p.Projects["keep"] != 0 {
		t.Fatalf("%+v %v", p, err)
	}
	for _, bad := range []string{"acme", "acme=x", "=5", "acme=-1"} {
		if _, err := ParseRetention(0, bad); err == nil {
			t.Errorf("%q should be rejected", bad)
		}
	}
	if (RetentionPolicy{Projects: map[string]int{"keep": 0}}).Enabled() {
		t.Error("nothing to delete: should be disabled")
	}
}

func TestPurgeExpired(t *testing.T) {
	now := time.Date(2026, 11, 18, 0, 0, 0, 0, time.UTC)
	daysAgo := func(d int) time.Time { return now.AddDate(0, 0, -d) }
	store := &fakeRetentionStore{
		sessions: map[string]fakeSession{
			"old-default": {"web", daysAgo(100)},
			"new-default": {"web", daysAgo(10)},
			"old-demo":    {"demo", daysAgo(8)},
			"new-demo":    {"demo", daysAgo(6)},
			"ancient-vip": {"vip", daysAgo(1000)}, // vip=0: kept forever
			"acme-200":    {"acme", daysAgo(200)}, // acme=365 overrides the default 90
			"stuck":       {"web", daysAgo(400)},
		},
		objects:       map[string]bool{},
		failObjectsOf: map[string]bool{"stuck": true},
	}
	for id := range store.sessions {
		store.objects[id] = true
	}
	p, _ := ParseRetention(90, "demo=7,vip=0,acme=365")

	n, err := PurgeExpired(context.Background(), store, p, now)
	if err != nil || n != 2 {
		t.Fatalf("deleted %d, %v", n, err)
	}
	var left []string
	for id := range store.sessions {
		left = append(left, id)
	}
	sort.Strings(left)
	want := []string{"acme-200", "ancient-vip", "new-default", "new-demo", "stuck"}
	if len(left) != len(want) {
		t.Fatalf("left %v, want %v", left, want)
	}
	for i := range want {
		if left[i] != want[i] {
			t.Fatalf("left %v, want %v", left, want)
		}
	}
	if store.objects["old-default"] || store.objects["old-demo"] {
		t.Fatal("deleted sessions' stored events must be gone too")
	}
	if !store.objects["stuck"] {
		t.Fatal("test setup: stuck's objects failed to delete")
	}

	// Storage back: the stuck session goes on the next pass.
	store.failObjectsOf = nil
	if n, _ := PurgeExpired(context.Background(), store, p, now); n != 1 || store.objects["stuck"] {
		t.Fatalf("retry deleted %d", n)
	}
}
