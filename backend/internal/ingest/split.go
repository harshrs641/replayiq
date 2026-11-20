package ingest

import (
	"encoding/json"
	"fmt"

	"github.com/harshrs641/replayiq/internal/models"
)

// MaxMessageBytes keeps Kafka messages well under the broker's default
// 1 MB limit; topics also allow up to 8 MB (kafka.MaxMessageBytes) for a
// single event that is larger on its own (a screenshot, a big web page
// snapshot).
const MaxMessageBytes = 800 << 10

// SplitBatch cuts a batch into parts whose JSON stays under maxBytes,
// keeping event order. Parts get batch ids "<id>.p<n>", so a retried batch
// produces the same parts and storage still replaces rather than
// duplicates them. A batch that fits is returned as is.
func SplitBatch(b *models.EventBatch, maxBytes int) []*models.EventBatch {
	whole, err := json.Marshal(b)
	if err != nil || len(whole) <= maxBytes {
		return []*models.EventBatch{b}
	}
	var parts []*models.EventBatch
	cur := &models.EventBatch{}
	size := 0
	flush := func() {
		if len(cur.Events) == 0 && len(cur.CustomEvents) == 0 {
			return
		}
		parts = append(parts, cur)
		cur = &models.EventBatch{}
		size = 0
	}
	for _, e := range b.Events {
		raw, _ := json.Marshal(e)
		if size > 0 && size+len(raw) > maxBytes {
			flush()
		}
		cur.Events = append(cur.Events, e)
		size += len(raw) + 1
	}
	flush()
	if len(parts) == 0 {
		parts = []*models.EventBatch{{}}
	}
	parts[0].CustomEvents = b.CustomEvents
	for i, p := range parts {
		p.SessionID, p.ProjectID, p.FlushedAt = b.SessionID, b.ProjectID, b.FlushedAt
		p.DeviceMasked, p.Platform, p.SDK = b.DeviceMasked, b.Platform, b.SDK
		if b.BatchID != "" {
			p.BatchID = fmt.Sprintf("%s.p%d", b.BatchID, i+1)
		}
	}
	return parts
}

// PublishBatch publishes a batch to topic, split into parts that fit a
// Kafka message.
func PublishBatch(p Publisher, topic string, b *models.EventBatch) error {
	for _, part := range SplitBatch(b, MaxMessageBytes) {
		if err := p.Publish(topic, part.SessionID, part); err != nil {
			return err
		}
	}
	return nil
}
