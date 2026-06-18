package storage

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
	"github.com/harshrs641/replayiq/internal/models"
)

// EmbeddingDims must match the embedding model configured via EMBEDDING_MODEL
// (nomic-embed-text produces 768-dim vectors).
//
// ─── Vector DB scaling note ───────────────────────────────────────────────────
// pgvector's HNSW index works well up to roughly 1 million vectors — beyond
// that the in-memory index saturates the Postgres shared_buffers and ANN
// recall degrades.  For enterprise deployments above that threshold, migrate
// vectors to a dedicated vector database:
//
//   Qdrant  (https://qdrant.tech)          — self-hosted, REST/gRPC, filtering
//   Weaviate (https://weaviate.io)         — self-hosted, GraphQL, hybrid search
//
// Migration path:
//  1. Stand up Qdrant/Weaviate alongside Postgres.
//  2. Backfill: iterate sessions with embedding IS NOT NULL, upsert into the
//     new store keyed by session id.
//  3. Update storage.Postgres.UpdateSessionEmbedding to write to the new
//     store instead of (or in addition to) the embedding column.
//  4. Replace SearchSessions with a call to the new store's ANN endpoint,
//     then fetch the returned ids from Postgres for the full session rows.
//  5. Drop the embedding column and the HNSW index from Postgres once
//     the migration is validated.
const EmbeddingDims = 768

// vectorLiteral renders an embedding as the text form pgvector expects
// (e.g. "[0.1,0.2,0.3]"), so it can be sent as a plain query parameter cast
// with ::vector instead of pulling in a dedicated pgvector driver type.
func vectorLiteral(v []float64) string {
	parts := make([]string, len(v))
	for i, f := range v {
		parts[i] = strconv.FormatFloat(f, 'f', -1, 64)
	}
	return "[" + strings.Join(parts, ",") + "]"
}

// ─── Postgres ─────────────────────────────────────────────────────────────────

// ─── Retention / cold archival ────────────────────────────────────────────────
//
// Hot-storage cost grows linearly with session volume.  For enterprise
// deployments set SESSION_RETENTION_DAYS to delete (or detach) sessions older
// than N days on each server startup.
//
// Archival strategy (implement before deleting):
//  1. Export sessions older than retention window to S3/GCS as Parquet
//     (use COPY … TO PROGRAM 'aws s3 cp …' or a separate export job).
//  2. Call PurgeOldSessions to remove them from hot Postgres storage.
//  3. Query the cold tier via Athena/BigQuery for historical analysis.
//
// With monthly partitioning (see enterprise partitioning DDL above)
// PurgeOldSessions becomes a cheap DETACH PARTITION instead of a DELETE.

type Postgres struct {
	pool     *pgxpool.Pool // write pool (primary)
	readPool *pgxpool.Pool // read pool (replica); equals pool when no replica
}

// r returns the read pool, used for SELECT queries that do not need to see
// the very latest write.  In dev (no replica) this is the same as pool.
func (p *Postgres) r() *pgxpool.Pool { return p.readPool }

// PurgeOldSessions deletes sessions (and their cascaded ai_issues rows)
// that were created more than retentionDays ago.  Returns the number of
// rows deleted.  Callers should export to cold storage before calling this.
func (p *Postgres) PurgeOldSessions(ctx context.Context, retentionDays int) (int64, error) {
	cutoff := time.Now().AddDate(0, 0, -retentionDays)
	tag, err := p.pool.Exec(ctx,
		`DELETE FROM sessions WHERE created_at < $1`, cutoff,
	)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

// NewPostgres opens write and read pools.  Pass an empty string or the same
// value for readDSN when you have no read replica (both pools point at the
// same server).
func NewPostgres(writeDSN, readDSN string) (*Postgres, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	writePool, err := pgxpool.New(ctx, writeDSN)
	if err != nil {
		return nil, fmt.Errorf("postgres write connect: %w", err)
	}
	if err := writePool.Ping(ctx); err != nil {
		return nil, fmt.Errorf("postgres write ping: %w", err)
	}

	var readPool *pgxpool.Pool
	if readDSN == "" || readDSN == writeDSN {
		readPool = writePool
	} else {
		readPool, err = pgxpool.New(ctx, readDSN)
		if err != nil {
			return nil, fmt.Errorf("postgres read connect: %w", err)
		}
		if err := readPool.Ping(ctx); err != nil {
			return nil, fmt.Errorf("postgres read ping: %w", err)
		}
	}
	return &Postgres{pool: writePool, readPool: readPool}, nil
}

// migrationLockID is the Postgres advisory lock key used to serialize schema
// migrations across multiple instances starting simultaneously (e.g. a
// rolling deploy with 3 replicas).  Only one process holds the lock at a
// time; the others block until the winner finishes and then find IF NOT
// EXISTS / IF EXISTS conditions already satisfied.
const migrationLockID = 0x52495100 // "RIQ\0" in hex

func (p *Postgres) Migrate() error {
	ctx := context.Background()

	conn, err := p.pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("acquire conn for migration: %w", err)
	}
	defer conn.Release()

	// Block until we hold the advisory lock.  Using the session-level lock
	// (pg_advisory_lock) so it is automatically released if the connection
	// drops mid-migration.
	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock($1)`, migrationLockID); err != nil {
		return fmt.Errorf("acquire migration lock: %w", err)
	}
	defer conn.Exec(context.Background(), `SELECT pg_advisory_unlock($1)`, migrationLockID) //nolint:errcheck

	_, err = conn.Exec(ctx, schema)
	return err
}

func (p *Postgres) CreateSession(ctx context.Context, s *models.Session) error {
	meta, _ := json.Marshal(s.Metadata)
	_, err := p.pool.Exec(ctx, `
		INSERT INTO sessions (id, project_id, user_id, url, user_agent, screen_width, screen_height,
			sdk_version, metadata, started_at, storage_path, created_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,NOW())
		ON CONFLICT (id) DO NOTHING`,
		s.ID, s.ProjectID, s.UserID, s.URL, s.UserAgent,
		s.ScreenWidth, s.ScreenHeight, s.SDKVersion, meta,
		s.StartedAt, s.StoragePath,
	)
	return err
}

func (p *Postgres) EndSession(ctx context.Context, sessionID string, endedAt time.Time, durationMs int64) error {
	_, err := p.pool.Exec(ctx,
		`UPDATE sessions SET ended_at=$1, duration_ms=$2 WHERE id=$3`,
		endedAt, durationMs, sessionID,
	)
	return err
}

func (p *Postgres) UpdateSessionAI(ctx context.Context, sessionID string, summary *models.SessionSummary) error {
	tags, _ := json.Marshal(summary.Tags)
	frustrations, _ := json.Marshal(summary.Frustrations)
	tokenized, _ := json.Marshal(summary.TokenizedEvents)
	now := time.Now()
	_, err := p.pool.Exec(ctx, `
		UPDATE sessions SET
			ai_summary=$1, ai_tokenized=$2, ai_tags=$3,
			ai_goal_achieved=$4, ai_frustrations=$5, ai_processed_at=$6
		WHERE id=$7`,
		summary.Narrative, string(tokenized), tags,
		summary.GoalAchieved, frustrations, now, sessionID,
	)
	return err
}

// UpdateSessionAIStatus records where a session currently is in the AI
// pipeline (queued/analyzing/embedding/complete/failed) so the dashboard can
// show live progress instead of a binary "has summary or not".
func (p *Postgres) UpdateSessionAIStatus(ctx context.Context, sessionID, status, errMsg string) error {
	_, err := p.pool.Exec(ctx,
		`UPDATE sessions SET ai_status=$1, ai_error=$2 WHERE id=$3`,
		status, errMsg, sessionID,
	)
	return err
}

func (p *Postgres) UpdateSessionEmbedding(ctx context.Context, sessionID string, embedding []float64) error {
	_, err := p.pool.Exec(ctx,
		`UPDATE sessions SET embedding=$1::vector WHERE id=$2`,
		vectorLiteral(embedding), sessionID,
	)
	return err
}

// SearchSessions returns the sessions in a project whose stored embedding is
// closest (cosine similarity) to queryEmbedding, most similar first.
func (p *Postgres) SearchSessions(ctx context.Context, projectID string, queryEmbedding []float64, limit int) ([]*models.Session, error) {
	rows, err := p.r().Query(ctx, `
		SELECT id, project_id, user_id, url, started_at, ended_at, duration_ms,
			event_count, ai_summary, ai_tags, ai_frustrations, ai_goal_achieved, created_at,
			1 - (embedding <=> $2::vector) AS similarity
		FROM sessions
		WHERE project_id=$1 AND embedding IS NOT NULL
		ORDER BY embedding <=> $2::vector
		LIMIT $3`,
		projectID, vectorLiteral(queryEmbedding), limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var sessions []*models.Session
	for rows.Next() {
		s := &models.Session{}
		var aiTags, aiFrustrations []byte
		if err := rows.Scan(&s.ID, &s.ProjectID, &s.UserID, &s.URL,
			&s.StartedAt, &s.EndedAt, &s.DurationMs, &s.EventCount,
			&s.AISummary, &aiTags, &aiFrustrations, &s.AIGoalAchieved, &s.CreatedAt,
			&s.SimilarityScore); err != nil {
			return nil, err
		}
		json.Unmarshal(aiTags, &s.AITags)
		json.Unmarshal(aiFrustrations, &s.AIFrustrations)
		sessions = append(sessions, s)
	}
	return sessions, nil
}

func (p *Postgres) IncrementEventCount(ctx context.Context, sessionID string, count int) error {
	_, err := p.pool.Exec(ctx,
		`UPDATE sessions SET event_count = event_count + $1 WHERE id=$2`,
		count, sessionID,
	)
	return err
}

func (p *Postgres) GetSession(ctx context.Context, sessionID string) (*models.Session, error) {
	row := p.r().QueryRow(ctx, `
		SELECT id, project_id, user_id, url, COALESCE(user_agent, ''), screen_width, screen_height,
			COALESCE(sdk_version, ''), metadata, started_at, ended_at, duration_ms, event_count,
			COALESCE(ai_summary, ''), COALESCE(ai_tokenized, ''), ai_tags, ai_goal_achieved, ai_frustrations,
			ai_processed_at, COALESCE(ai_status, 'pending'), COALESCE(ai_error, ''),
			COALESCE(storage_path, ''), created_at
		FROM sessions WHERE id=$1`, sessionID)

	s := &models.Session{}
	var meta []byte
	var aiTags, aiFrustrations, tags []byte
	err := row.Scan(
		&s.ID, &s.ProjectID, &s.UserID, &s.URL, &s.UserAgent,
		&s.ScreenWidth, &s.ScreenHeight, &s.SDKVersion, &meta,
		&s.StartedAt, &s.EndedAt, &s.DurationMs, &s.EventCount,
		&s.AISummary, &s.AITokenized, &aiTags, &s.AIGoalAchieved, &aiFrustrations,
		&s.AIProcessedAt, &s.AIStatus, &s.AIError, &s.StoragePath, &s.CreatedAt,
	)
	if err != nil {
		return nil, err
	}
	json.Unmarshal(meta, &s.Metadata)
	json.Unmarshal(aiTags, &s.AITags)
	json.Unmarshal(aiFrustrations, &s.AIFrustrations)
	json.Unmarshal(tags, &s.Tags)
	return s, nil
}

// ListAllSessionIDs returns every session id in the system, across all
// projects, oldest first. Used by the mask-backfill tool to find sessions
// recorded before the masked-replay feature shipped.
func (p *Postgres) ListAllSessionIDs(ctx context.Context) ([]string, error) {
	rows, err := p.r().Query(ctx, `SELECT id FROM sessions ORDER BY created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

func (p *Postgres) ListSessions(ctx context.Context, projectID string, limit, offset int) ([]*models.Session, int, error) {
	// Run the total count and the page query concurrently — they are
	// independent reads and the combined latency is max(count, data)
	// instead of sum(count, data).
	type countResult struct {
		n   int
		err error
	}
	countCh := make(chan countResult, 1)
	go func() {
		var n int
		err := p.r().QueryRow(ctx, `SELECT COUNT(*) FROM sessions WHERE project_id=$1`, projectID).Scan(&n)
		countCh <- countResult{n, err}
	}()

	rows, err := p.r().Query(ctx, `
		SELECT id, project_id, user_id, url, started_at, ended_at, duration_ms,
			event_count, COALESCE(ai_summary, ''), ai_tags, ai_frustrations, ai_goal_achieved,
			COALESCE(ai_status, 'pending'), COALESCE(ai_error, ''), created_at
		FROM sessions WHERE project_id=$1
		ORDER BY created_at DESC LIMIT $2 OFFSET $3`,
		projectID, limit, offset,
	)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var sessions []*models.Session
	for rows.Next() {
		s := &models.Session{}
		var aiTags, aiFrustrations []byte
		if err := rows.Scan(&s.ID, &s.ProjectID, &s.UserID, &s.URL,
			&s.StartedAt, &s.EndedAt, &s.DurationMs, &s.EventCount,
			&s.AISummary, &aiTags, &aiFrustrations, &s.AIGoalAchieved,
			&s.AIStatus, &s.AIError, &s.CreatedAt); err != nil {
			return nil, 0, err
		}
		json.Unmarshal(aiTags, &s.AITags)
		json.Unmarshal(aiFrustrations, &s.AIFrustrations)
		sessions = append(sessions, s)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	cr := <-countCh
	if cr.err != nil {
		return nil, 0, cr.err
	}
	return sessions, cr.n, nil
}

func (p *Postgres) CreateIssue(ctx context.Context, issue *models.AIIssue) error {
	tags, _ := json.Marshal(issue.Tags)
	_, err := p.pool.Exec(ctx, `
		INSERT INTO ai_issues (id, session_id, project_id, type, title, description, severity, tags, created_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,NOW())`,
		issue.ID, issue.SessionID, issue.ProjectID,
		issue.Type, issue.Title, issue.Description,
		issue.Severity, tags,
	)
	return err
}

func (p *Postgres) UpdateIssueJira(ctx context.Context, issueID, jiraKey, jiraURL string) error {
	_, err := p.pool.Exec(ctx,
		`UPDATE ai_issues SET jira_key=$1, jira_url=$2 WHERE id=$3`,
		jiraKey, jiraURL, issueID,
	)
	return err
}

func (p *Postgres) ListIssues(ctx context.Context, projectID string, limit int) ([]*models.AIIssue, error) {
	rows, err := p.r().Query(ctx, `
		SELECT id, session_id, project_id, type, title, description, severity, tags, jira_key, jira_url, created_at
		FROM ai_issues WHERE project_id=$1 ORDER BY created_at DESC LIMIT $2`,
		projectID, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var issues []*models.AIIssue
	for rows.Next() {
		iss := &models.AIIssue{}
		var tags []byte
		rows.Scan(&iss.ID, &iss.SessionID, &iss.ProjectID, &iss.Type,
			&iss.Title, &iss.Description, &iss.Severity, &tags,
			&iss.JiraKey, &iss.JiraURL, &iss.CreatedAt)
		json.Unmarshal(tags, &iss.Tags)
		issues = append(issues, iss)
	}
	return issues, nil
}

var schema = fmt.Sprintf(`
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS sessions (
	id              TEXT PRIMARY KEY,
	project_id      TEXT NOT NULL,
	user_id         TEXT NOT NULL,
	url             TEXT NOT NULL,
	user_agent      TEXT,
	screen_width    INT DEFAULT 0,
	screen_height   INT DEFAULT 0,
	sdk_version     TEXT,
	metadata        JSONB DEFAULT '{}',
	started_at      TIMESTAMPTZ,
	ended_at        TIMESTAMPTZ,
	duration_ms     BIGINT DEFAULT 0,
	event_count     INT DEFAULT 0,
	tags            JSONB DEFAULT '[]',
	ai_summary      TEXT,
	ai_tokenized    TEXT,
	ai_tags         JSONB DEFAULT '[]',
	ai_goal_achieved BOOLEAN,
	ai_frustrations  JSONB DEFAULT '[]',
	ai_processed_at  TIMESTAMPTZ,
	ai_status       TEXT DEFAULT 'pending',
	ai_error        TEXT,
	storage_path    TEXT,
	created_at      TIMESTAMPTZ DEFAULT NOW(),
	embedding       vector(%d)
);

-- Patch existing installs created before these columns existed.
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS embedding vector(%d);
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS ai_status TEXT DEFAULT 'pending';
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS ai_error TEXT;
UPDATE sessions SET ai_status = 'complete' WHERE ai_status = 'pending' AND ai_processed_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project_id);
CREATE INDEX IF NOT EXISTS idx_sessions_created ON sessions(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_sessions_embedding ON sessions USING hnsw (embedding vector_cosine_ops);

CREATE TABLE IF NOT EXISTS ai_issues (
	id          TEXT PRIMARY KEY DEFAULT gen_random_uuid()::TEXT,
	session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
	project_id  TEXT NOT NULL,
	type        TEXT NOT NULL,
	title       TEXT NOT NULL,
	description TEXT,
	severity    TEXT DEFAULT 'P2',
	tags        JSONB DEFAULT '[]',
	jira_key    TEXT,
	jira_url    TEXT,
	created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_issues_project ON ai_issues(project_id);
CREATE INDEX IF NOT EXISTS idx_issues_session ON ai_issues(session_id);

-- ─── Enterprise partitioning (run manually — not applied automatically) ───────
--
-- At ~1M sessions the sessions table benefits from monthly range
-- partitioning on created_at so queries with date filters prune whole
-- partitions and VACUUM stays cheap.
--
-- Partitioned tables require the partition key to be part of the PRIMARY
-- KEY, and foreign keys must reference that composite key.  Converting an
-- existing install is a data-migration operation (create new partitioned
-- table, copy rows, swap names, rebuild ai_issues FK).
-- For a NEW enterprise install, replace the sessions DDL above with:
--
--   CREATE TABLE sessions (
--     id          TEXT        NOT NULL,
--     created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
--     ...         (same columns as above)
--     PRIMARY KEY (id, created_at),
--     embedding   vector(%d)
--   ) PARTITION BY RANGE (created_at);
--
--   -- Default catch-all partition (holds rows that predate explicit monthly slices)
--   CREATE TABLE sessions_default PARTITION OF sessions DEFAULT;
--
--   -- Create monthly partitions (or automate with pg_partman):
--   CREATE TABLE sessions_2026_01 PARTITION OF sessions
--     FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
--
--   -- Update ai_issues FK to include created_at:
--   ALTER TABLE ai_issues ADD COLUMN session_created_at TIMESTAMPTZ NOT NULL;
--   ALTER TABLE ai_issues ADD CONSTRAINT fk_ai_issues_session
--     FOREIGN KEY (session_id, session_created_at)
--     REFERENCES sessions(id, created_at) ON DELETE CASCADE;
--
-- Use pg_partman (https://github.com/pgpartman/pg_partman) to automate
-- partition creation and old-partition detachment/archival.
`, EmbeddingDims, EmbeddingDims, EmbeddingDims)

// ─── MinIO ────────────────────────────────────────────────────────────────────

type MinIO struct {
	client *minio.Client
	bucket string
	// maskedBucket holds the redacted copy of every event batch, written
	// alongside the raw one on ingest (see StoreMaskedEvents). Kept as a
	// separate bucket - rather than a prefix in the same bucket - so the
	// two can have different access policies/lifecycle rules in an
	// enterprise deployment (e.g. the raw bucket locked down to a narrow
	// set of principals, the masked bucket open to general support staff).
	maskedBucket string
}

func NewMinIO(endpoint, accessKey, secretKey, bucket, maskedBucket string, secure bool) (*MinIO, error) {
	client, err := minio.New(endpoint, &minio.Options{
		Creds:  credentials.NewStaticV4(accessKey, secretKey, ""),
		Secure: secure,
	})
	if err != nil {
		return nil, fmt.Errorf("minio init: %w", err)
	}

	ctx := context.Background()
	for _, b := range []string{bucket, maskedBucket} {
		if err := ensureBucket(ctx, client, b); err != nil {
			return nil, err
		}
	}
	return &MinIO{client: client, bucket: bucket, maskedBucket: maskedBucket}, nil
}

func ensureBucket(ctx context.Context, client *minio.Client, bucket string) error {
	exists, err := client.BucketExists(ctx, bucket)
	if err != nil {
		return err
	}
	if !exists {
		if err := client.MakeBucket(ctx, bucket, minio.MakeBucketOptions{}); err != nil {
			return err
		}
	}
	return nil
}

func (m *MinIO) StoreEvents(ctx context.Context, sessionID string, batch *models.EventBatch) (string, error) {
	return m.store(ctx, m.bucket, sessionID, batch)
}

// StoreMaskedEvents persists the redacted copy of batch (see package
// masking) under the same key shape as StoreEvents, but in maskedBucket -
// this is the "*_masked" view the replay toggle reads by default.
func (m *MinIO) StoreMaskedEvents(ctx context.Context, sessionID string, batch *models.EventBatch) (string, error) {
	return m.store(ctx, m.maskedBucket, sessionID, batch)
}

// storeKeySeq guarantees unique object keys even when store() is called
// repeatedly within the same millisecond (e.g. the mask-backfill tool
// writing many batches back-to-back) - without it, two calls landing in the
// same millisecond produced the same key and the second PutObject silently
// overwrote the first, quietly dropping events from storage.
var storeKeySeq atomic.Uint64

func (m *MinIO) store(ctx context.Context, bucket, sessionID string, batch *models.EventBatch) (string, error) {
	data, err := json.Marshal(batch)
	if err != nil {
		return "", err
	}
	seq := storeKeySeq.Add(1)
	key := fmt.Sprintf("sessions/%s/%d-%d.json", sessionID, time.Now().UnixMilli(), seq)
	_, err = m.client.PutObject(ctx, bucket, key, bytes.NewReader(data), int64(len(data)),
		minio.PutObjectOptions{ContentType: "application/json"},
	)
	return key, err
}

func (m *MinIO) GetSessionEvents(ctx context.Context, sessionID string) ([]models.EventBatch, error) {
	return m.getEvents(ctx, m.bucket, sessionID)
}

// GetSessionMaskedEvents returns the redacted copy of a session's events,
// for serving the masked replay view by default.
func (m *MinIO) GetSessionMaskedEvents(ctx context.Context, sessionID string) ([]models.EventBatch, error) {
	return m.getEvents(ctx, m.maskedBucket, sessionID)
}

// DeleteSessionMaskedEvents removes every stored masked-event object for a
// session. StoreMaskedEvents always writes a new timestamped key rather
// than overwriting one in place, so re-masking a session that already has
// a masked copy (e.g. backfill-mask -force, or re-running masking after a
// rule change) would otherwise leave the old, stale objects behind
// alongside the new ones and double up events on replay. Callers that want
// to regenerate a session's masked copy should call this first.
func (m *MinIO) DeleteSessionMaskedEvents(ctx context.Context, sessionID string) error {
	prefix := fmt.Sprintf("sessions/%s/", sessionID)

	objectsCh := make(chan minio.ObjectInfo)
	go func() {
		defer close(objectsCh)
		for obj := range m.client.ListObjects(ctx, m.maskedBucket, minio.ListObjectsOptions{Prefix: prefix, Recursive: true}) {
			if obj.Err == nil {
				objectsCh <- obj
			}
		}
	}()

	for result := range m.client.RemoveObjects(ctx, m.maskedBucket, objectsCh, minio.RemoveObjectsOptions{}) {
		if result.Err != nil {
			return result.Err
		}
	}
	return nil
}

func (m *MinIO) getEvents(ctx context.Context, bucket, sessionID string) ([]models.EventBatch, error) {
	prefix := fmt.Sprintf("sessions/%s/", sessionID)
	var batches []models.EventBatch

	for obj := range m.client.ListObjects(ctx, bucket, minio.ListObjectsOptions{Prefix: prefix, Recursive: true}) {
		if obj.Err != nil {
			continue
		}
		reader, err := m.client.GetObject(ctx, bucket, obj.Key, minio.GetObjectOptions{})
		if err != nil {
			continue
		}
		var batch models.EventBatch
		json.NewDecoder(reader).Decode(&batch)
		reader.Close()
		batches = append(batches, batch)
	}
	return batches, nil
}

// hasEvents returns true if at least one event object exists for sessionID in
// bucket. It uses a single ListObjects call and stops at the first result, so
// it is cheap even for very large sessions.
func (m *MinIO) hasEvents(ctx context.Context, bucket, sessionID string) bool {
	prefix := fmt.Sprintf("sessions/%s/", sessionID)
	for obj := range m.client.ListObjects(ctx, bucket, minio.ListObjectsOptions{Prefix: prefix, Recursive: true}) {
		if obj.Err == nil {
			return true
		}
	}
	return false
}

// HasMaskedEvents reports whether any masked event objects exist for the session.
func (m *MinIO) HasMaskedEvents(ctx context.Context, sessionID string) bool {
	return m.hasEvents(ctx, m.maskedBucket, sessionID)
}

// StreamSessionEvents writes the raw event batches for sessionID as a JSON
// array directly into w, one batch at a time. It returns the number of batches
// written and any error encountered mid-stream. This avoids loading the full
// session into memory before sending.
func (m *MinIO) StreamSessionEvents(ctx context.Context, sessionID string, w io.Writer) (int, error) {
	return m.streamEvents(ctx, m.bucket, sessionID, w)
}

// StreamSessionMaskedEvents is the masked-copy variant of StreamSessionEvents.
func (m *MinIO) StreamSessionMaskedEvents(ctx context.Context, sessionID string, w io.Writer) (int, error) {
	return m.streamEvents(ctx, m.maskedBucket, sessionID, w)
}

// streamEvents iterates over every stored object for sessionID in bucket and
// writes each raw JSON blob directly into w as an element of a JSON array.
// The caller is responsible for writing the surrounding `[` and `]` tokens.
func (m *MinIO) streamEvents(ctx context.Context, bucket, sessionID string, w io.Writer) (int, error) {
	prefix := fmt.Sprintf("sessions/%s/", sessionID)
	count := 0

	for obj := range m.client.ListObjects(ctx, bucket, minio.ListObjectsOptions{Prefix: prefix, Recursive: true}) {
		if obj.Err != nil {
			continue
		}
		reader, err := m.client.GetObject(ctx, bucket, obj.Key, minio.GetObjectOptions{})
		if err != nil {
			continue
		}

		if count > 0 {
			if _, err := io.WriteString(w, ","); err != nil {
				reader.Close()
				return count, err
			}
		}
		_, copyErr := io.Copy(w, reader)
		reader.Close()
		if copyErr != nil {
			return count, copyErr
		}
		count++
	}
	return count, nil
}

// CountSessionEvents returns the number of stored event batch objects for
// sessionID in the raw bucket.  Used by the AI Worker to verify the Storage
// Worker has finished flushing events to MinIO before starting analysis.
func (m *MinIO) CountSessionEvents(ctx context.Context, sessionID string) (int, error) {
	prefix := fmt.Sprintf("sessions/%s/", sessionID)
	count := 0
	for obj := range m.client.ListObjects(ctx, m.bucket, minio.ListObjectsOptions{Prefix: prefix, Recursive: true}) {
		if obj.Err != nil {
			return 0, obj.Err
		}
		count++
	}
	return count, nil
}

func (m *MinIO) PresignedURL(ctx context.Context, key string) (string, error) {
	u, err := m.client.PresignedGetObject(ctx, m.bucket, key, 1*time.Hour, nil)
	if err != nil {
		return "", err
	}
	return u.String(), nil
}
