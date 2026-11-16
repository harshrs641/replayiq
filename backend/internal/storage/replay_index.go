package storage

// Streaming replay support.
//
// A session is stored as many small event-batch objects. To let a player
// stream a replay (load the first seconds, then fetch ahead) and jump to any
// time without downloading everything before it, each object carries a tiny
// index in its S3 user metadata, written once by store():
//
//	Riq-First / Riq-Last   min / max event timestamp in the batch
//	Riq-Count              number of events
//	Riq-Fulls              FullSnapshot (type 2) timestamps: places a replay can start from
//	Riq-Metas              Meta (type 4) timestamps: rrweb needs one before each FullSnapshot
//
// Listing a session with metadata gives the whole timeline without reading a
// single event. Objects written before this existed are indexed by reading
// them once; the result is cached in memory (objects are immutable).

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"sort"
	"strconv"
	"strings"
	"sync"

	"github.com/minio/minio-go/v7"
)

const (
	rrwebFullSnapshot = 2
	rrwebMeta         = 4
	rrwebCustom       = 5

	metaFirst = "Riq-First"
	metaLast  = "Riq-Last"
	metaCount = "Riq-Count"
	metaFulls = "Riq-Fulls"
	metaMetas = "Riq-Metas"

	// S3 caps user metadata at 2 KB per object; a 13-digit timestamp plus a
	// comma is 14 bytes, so 48 per list keeps both lists well under it.
	maxIndexedPerList = 48
)

// BatchIndex describes one stored event-batch object.
type BatchIndex struct {
	Key   string  `json:"-"`
	First int64   `json:"first"`
	Last  int64   `json:"last"`
	Count int     `json:"count"`
	Bytes int64   `json:"bytes"`
	Fulls []int64 `json:"-"`
	Metas []int64 `json:"-"`
}

// eventHeader is the part of an rrweb event the streaming code looks at;
// the rest is passed through as raw JSON, byte for byte.
type eventHeader struct {
	Type      int    `json:"type"`
	Timestamp int64  `json:"timestamp"`
	Subtype   string `json:"subtype"`
}

type rawBatch struct {
	Events []json.RawMessage `json:"events"`
}

// indexEvents builds the index for a batch's events. It works on headers
// so both store() (typed events) and legacy objects (raw JSON) share it.
func indexEvents(headers []eventHeader) BatchIndex {
	var ix BatchIndex
	for i, h := range headers {
		if i == 0 || h.Timestamp < ix.First {
			ix.First = h.Timestamp
		}
		if i == 0 || h.Timestamp > ix.Last {
			ix.Last = h.Timestamp
		}
		switch h.Type {
		case rrwebFullSnapshot:
			ix.Fulls = append(ix.Fulls, h.Timestamp)
		case rrwebMeta:
			ix.Metas = append(ix.Metas, h.Timestamp)
		}
	}
	ix.Count = len(headers)
	ix.Fulls = thin(ix.Fulls, maxIndexedPerList)
	ix.Metas = thin(ix.Metas, maxIndexedPerList)
	return ix
}

// thin keeps at most n values, evenly spread and always keeping the first
// and last. Dropping some FullSnapshots only means a jump may start a little
// earlier than strictly necessary; it never breaks playback.
func thin(ts []int64, n int) []int64 {
	sort.Slice(ts, func(i, j int) bool { return ts[i] < ts[j] })
	if len(ts) <= n {
		return ts
	}
	out := make([]int64, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, ts[i*(len(ts)-1)/(n-1)])
	}
	return out
}

func joinTS(ts []int64) string {
	parts := make([]string, len(ts))
	for i, t := range ts {
		parts[i] = strconv.FormatInt(t, 10)
	}
	return strings.Join(parts, ",")
}

func splitTS(s string) []int64 {
	if s == "" {
		return nil
	}
	var out []int64
	for _, p := range strings.Split(s, ",") {
		if t, err := strconv.ParseInt(strings.TrimSpace(p), 10, 64); err == nil {
			out = append(out, t)
		}
	}
	return out
}

// toMetadata renders the index as S3 user metadata (minio-go adds the
// X-Amz-Meta- prefix).
func (ix BatchIndex) toMetadata() map[string]string {
	return map[string]string{
		metaFirst: strconv.FormatInt(ix.First, 10),
		metaLast:  strconv.FormatInt(ix.Last, 10),
		metaCount: strconv.Itoa(ix.Count),
		metaFulls: joinTS(ix.Fulls),
		metaMetas: joinTS(ix.Metas),
	}
}

// indexFromMetadata reads the index back from a listing. Header names come
// back in varying case and with or without the X-Amz-Meta- prefix depending
// on the server, so match loosely.
func indexFromMetadata(md map[string]string) (BatchIndex, bool) {
	get := func(name string) (string, bool) {
		for k, v := range md {
			k = strings.TrimPrefix(strings.ToLower(k), "x-amz-meta-")
			if k == strings.ToLower(name) {
				return v, true
			}
		}
		return "", false
	}
	firstS, ok1 := get(metaFirst)
	lastS, ok2 := get(metaLast)
	if !ok1 || !ok2 {
		return BatchIndex{}, false
	}
	var ix BatchIndex
	var err error
	if ix.First, err = strconv.ParseInt(firstS, 10, 64); err != nil {
		return BatchIndex{}, false
	}
	if ix.Last, err = strconv.ParseInt(lastS, 10, 64); err != nil {
		return BatchIndex{}, false
	}
	c, _ := get(metaCount)
	ix.Count, _ = strconv.Atoi(c)
	f, _ := get(metaFulls)
	ix.Fulls = splitTS(f)
	mt, _ := get(metaMetas)
	ix.Metas = splitTS(mt)
	return ix, true
}

// legacyIndexCache holds indexes computed by reading objects that predate
// the metadata index. Keyed by bucket/key/etag; bounded by a simple reset.
var legacyIndexCache = struct {
	sync.Mutex
	m map[string]BatchIndex
}{m: map[string]BatchIndex{}}

const legacyIndexCacheMax = 20000

func (m *MinIO) bucketFor(masked bool) string {
	if masked {
		return m.maskedBucket
	}
	return m.bucket
}

// readRawBatch fetches and decodes one object into raw events.
func (m *MinIO) readRawBatch(ctx context.Context, bucket, key string) ([]json.RawMessage, error) {
	obj, err := m.client.GetObject(ctx, bucket, key, minio.GetObjectOptions{})
	if err != nil {
		return nil, err
	}
	defer obj.Close()
	body, err := openBatch(obj)
	if err != nil {
		return nil, err
	}
	var b rawBatch
	if err := json.NewDecoder(body).Decode(&b); err != nil {
		return nil, fmt.Errorf("decode %s: %w", key, err)
	}
	return b.Events, nil
}

func headersOf(events []json.RawMessage) []eventHeader {
	hs := make([]eventHeader, len(events))
	for i, e := range events {
		json.Unmarshal(e, &hs[i])
	}
	return hs
}

// SessionIndex lists a session's batches with their time index, sorted by
// first timestamp. Empty batches are dropped.
func (m *MinIO) SessionIndex(ctx context.Context, masked bool, sessionID string) ([]BatchIndex, error) {
	bucket := m.bucketFor(masked)
	prefix := fmt.Sprintf("sessions/%s/", sessionID)
	var out []BatchIndex
	legacy := 0
	for obj := range m.client.ListObjects(ctx, bucket, minio.ListObjectsOptions{Prefix: prefix, Recursive: true, WithMetadata: true}) {
		if obj.Err != nil {
			return nil, obj.Err
		}
		ix, ok := indexFromMetadata(obj.UserMetadata)
		if !ok {
			cacheKey := bucket + "/" + obj.Key + "/" + obj.ETag
			legacyIndexCache.Lock()
			cached, hit := legacyIndexCache.m[cacheKey]
			legacyIndexCache.Unlock()
			if hit {
				ix = cached
			} else {
				events, err := m.readRawBatch(ctx, bucket, obj.Key)
				if err != nil {
					continue
				}
				ix = indexEvents(headersOf(events))
				legacy++
				legacyIndexCache.Lock()
				if len(legacyIndexCache.m) >= legacyIndexCacheMax {
					legacyIndexCache.m = map[string]BatchIndex{}
				}
				legacyIndexCache.m[cacheKey] = ix
				legacyIndexCache.Unlock()
			}
		}
		if ix.Count == 0 {
			continue
		}
		ix.Key = obj.Key
		ix.Bytes = obj.Size
		out = append(out, ix)
	}
	if legacy > 0 {
		log.Printf("replay index: %s: %d of %d batches had no stored index and were read in full (cached)", sessionID, legacy, len(out))
	}
	sort.Slice(out, func(i, j int) bool { return out[i].First < out[j].First })
	return out, nil
}

// Keyframes returns every indexed FullSnapshot timestamp, sorted and unique.
func Keyframes(idx []BatchIndex) []int64 {
	seen := map[int64]bool{}
	var out []int64
	for _, b := range idx {
		for _, t := range b.Fulls {
			if !seen[t] {
				seen[t] = true
				out = append(out, t)
			}
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

// lastMetaAtOrBefore finds the batch holding the latest Meta event at or
// before ts.
func lastMetaAtOrBefore(idx []BatchIndex, ts int64) (key string, metaTS int64, ok bool) {
	for _, b := range idx {
		for _, t := range b.Metas {
			if t <= ts && (!ok || t > metaTS) {
				key, metaTS, ok = b.Key, t, true
			}
		}
	}
	return
}

// eventFilter decides which events a stream includes.
type eventFilter func(h eventHeader) bool

// InRange keeps events with from <= timestamp < to.
func InRange(from, to int64) eventFilter {
	return func(h eventHeader) bool { return h.Timestamp >= from && h.Timestamp < to }
}

// ActivityOnly keeps Meta events (navigation) and the SDK's tagged custom
// events (click, input, console, network, ...), skipping screenshots, DOM
// mutations and mobile wireframes.
func ActivityOnly() eventFilter {
	return func(h eventHeader) bool {
		return h.Type == rrwebMeta || (h.Type == rrwebCustom && h.Subtype != "")
	}
}

// StreamEvents writes the events of the batches overlapping [from, to) that
// pass keep, as comma-separated JSON array elements (the caller writes the
// brackets). Pass from=math.MinInt64/to=math.MaxInt64 for the whole session.
//
// When startAtKeyframe is set, the stream is made independently playable
// from `from`: rrweb only starts rendering at a Meta event followed by a
// FullSnapshot, so the latest Meta at or before `from` is emitted first,
// retimed to `from`, unless a real Meta already sits exactly at `from`.
func (m *MinIO) StreamEvents(ctx context.Context, masked bool, idx []BatchIndex, from, to int64,
	startAtKeyframe bool, keep eventFilter, w io.Writer) (int, error) {
	bucket := m.bucketFor(masked)
	n := 0
	write := func(raw []byte) error {
		if n > 0 {
			if _, err := io.WriteString(w, ","); err != nil {
				return err
			}
		}
		n++
		_, err := w.Write(raw)
		return err
	}

	if startAtKeyframe {
		if key, metaTS, ok := lastMetaAtOrBefore(idx, from); ok && metaTS != from {
			events, err := m.readRawBatch(ctx, bucket, key)
			if err == nil {
				for _, e := range events {
					var h eventHeader
					if json.Unmarshal(e, &h) == nil && h.Type == rrwebMeta && h.Timestamp == metaTS {
						var full map[string]any
						if json.Unmarshal(e, &full) == nil {
							full["timestamp"] = from
							if b, err := json.Marshal(full); err == nil {
								if err := write(b); err != nil {
									return n, err
								}
							}
						}
						break
					}
				}
			}
		}
	}

	for _, b := range idx {
		if b.Last < from || b.First >= to {
			continue
		}
		events, err := m.readRawBatch(ctx, bucket, b.Key)
		if err != nil {
			continue
		}
		for _, e := range events {
			var h eventHeader
			if json.Unmarshal(e, &h) != nil {
				continue
			}
			if h.Timestamp < from || h.Timestamp >= to || (keep != nil && !keep(h)) {
				continue
			}
			if err := write(e); err != nil {
				return n, err
			}
		}
	}
	return n, nil
}
