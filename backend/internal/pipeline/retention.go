package pipeline

import (
	"context"
	"fmt"
	"log/slog"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/harshrs641/replayiq/internal/storage"
)

// RetentionPolicy says how long sessions are kept: DefaultDays for every
// project, except those listed in Projects. 0 days = keep forever.
type RetentionPolicy struct {
	DefaultDays int
	Projects    map[string]int
}

// ParseRetention reads SESSION_RETENTION_DAYS (the default) and
// SESSION_RETENTION_DAYS_BY_PROJECT ("acme=365,demo=7"; 0 keeps forever).
func ParseRetention(defaultDays int, byProject string) (RetentionPolicy, error) {
	p := RetentionPolicy{DefaultDays: defaultDays, Projects: map[string]int{}}
	for _, part := range strings.Split(byProject, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		name, days, ok := strings.Cut(part, "=")
		n, err := strconv.Atoi(strings.TrimSpace(days))
		if !ok || err != nil || n < 0 || strings.TrimSpace(name) == "" {
			return p, fmt.Errorf("SESSION_RETENTION_DAYS_BY_PROJECT: bad entry %q (want project=days)", part)
		}
		p.Projects[strings.TrimSpace(name)] = n
	}
	return p, nil
}

// Enabled reports whether anything is ever deleted.
func (p RetentionPolicy) Enabled() bool {
	if p.DefaultDays > 0 {
		return true
	}
	for _, d := range p.Projects {
		if d > 0 {
			return true
		}
	}
	return false
}

// RetentionRule selects expired sessions: those of Project (or, when
// Default, of every project not listed elsewhere) created before Cutoff.
type RetentionRule struct {
	Project string
	Default bool
	Except  []string
	Cutoff  time.Time
}

// Rules turns the policy into the queries one pass runs at now.
func (p RetentionPolicy) Rules(now time.Time) []RetentionRule {
	var rules []RetentionRule
	listed := make([]string, 0, len(p.Projects))
	for name, days := range p.Projects {
		listed = append(listed, name)
		if days > 0 {
			rules = append(rules, RetentionRule{Project: name, Cutoff: now.AddDate(0, 0, -days)})
		}
	}
	sort.Strings(listed)
	sort.Slice(rules, func(i, j int) bool { return rules[i].Project < rules[j].Project })
	if p.DefaultDays > 0 {
		rules = append(rules, RetentionRule{Default: true, Except: listed, Cutoff: now.AddDate(0, 0, -p.DefaultDays)})
	}
	return rules
}

// retentionStore is what the retention job needs from Postgres and MinIO.
type retentionStore interface {
	ExpiredSessionIDs(ctx context.Context, r RetentionRule, limit int) ([]string, error)
	DeleteSessionObjects(ctx context.Context, sessionID string) error
	DeleteSessions(ctx context.Context, ids []string) (int64, error)
}

const retentionBatch = 500

// PurgeExpired deletes every session the policy has expired: first its
// stored events (both copies), then its rows (AI issues cascade). Storage
// goes first so a failure never leaves objects without a row pointing at
// them; a session whose objects failed to delete keeps its row and is
// retried on the next pass.
func PurgeExpired(ctx context.Context, store retentionStore, p RetentionPolicy, now time.Time) (int64, error) {
	var total int64
	for _, rule := range p.Rules(now) {
		for {
			ids, err := store.ExpiredSessionIDs(ctx, rule, retentionBatch)
			if err != nil {
				return total, err
			}
			if len(ids) == 0 {
				break
			}
			deletable := ids[:0]
			for _, id := range ids {
				if err := store.DeleteSessionObjects(ctx, id); err != nil {
					slog.Warn("retention: delete stored events failed", "session_id", id, "error", err)
					continue
				}
				deletable = append(deletable, id)
			}
			n, err := store.DeleteSessions(ctx, deletable)
			total += n
			if err != nil {
				return total, err
			}
			if len(deletable) < len(ids) || len(ids) < retentionBatch {
				break // the failures would come back in the next query
			}
		}
	}
	return total, nil
}

// RunRetention purges expired sessions now and then every interval until
// ctx is done.
func RunRetention(ctx context.Context, store retentionStore, p RetentionPolicy, interval time.Duration) {
	if !p.Enabled() {
		return
	}
	for {
		n, err := PurgeExpired(ctx, store, p, time.Now())
		if err != nil && ctx.Err() == nil {
			slog.Error("session retention pass failed", "deleted", n, "error", err)
		} else if n > 0 {
			slog.Info("session retention: deleted expired sessions", "count", n)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(interval):
		}
	}
}

// StorageRetention runs retention against Postgres and MinIO.
type StorageRetention struct {
	DB    *storage.Postgres
	MinIO *storage.MinIO
}

func (s StorageRetention) ExpiredSessionIDs(ctx context.Context, r RetentionRule, limit int) ([]string, error) {
	return s.DB.ExpiredSessionIDs(ctx, r.Project, r.Default, r.Except, r.Cutoff, limit)
}

func (s StorageRetention) DeleteSessionObjects(ctx context.Context, sessionID string) error {
	return s.MinIO.DeleteSessionEvents(ctx, sessionID)
}

func (s StorageRetention) DeleteSessions(ctx context.Context, ids []string) (int64, error) {
	return s.DB.DeleteSessions(ctx, ids)
}
