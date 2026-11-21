// Package ingest is the stage between the ingest API and storage: it turns
// a batch as an SDK sent it into what storage, replay and the AI use.
//
//	SDK → ingest API (auth, limits, validation) → events.native (Kafka)
//	    → Processor: keep the native copy, convert to rrweb (package
//	      transform), mask → events.raw / events.masked → storage workers
//
// In the all-in-one server (no Kafka) the API calls Process inline and it
// stores directly.
package ingest

import (
	"context"
	"fmt"
	"net/url"
	"strings"

	"github.com/harshrs641/replayiq/internal/kafka"
	"github.com/harshrs641/replayiq/internal/masking"
	"github.com/harshrs641/replayiq/internal/models"
	"github.com/harshrs641/replayiq/internal/storage"
	"github.com/harshrs641/replayiq/internal/transform"
)

// Publisher sends a message to a Kafka topic.
type Publisher interface {
	Publish(topic, key string, value any) error
}

// Processor converts, masks and forwards (or stores) batches.
type Processor struct {
	MinIO   *storage.MinIO
	Masking masking.Config
	Tracker *masking.Tracker
	// Publisher, when set, sends results to events.raw/events.masked for the
	// storage workers; when nil (monolith) Process stores them itself.
	Publisher Publisher
	// PublicAPIURL is the API's address as the dashboard's browser reaches
	// it; replays load assets (images, fonts) from it.
	PublicAPIURL string
}

// AssetURL is where the player loads a project's asset from.
func (p *Processor) AssetURL(projectID, hash string) string {
	return fmt.Sprintf("%s/api/v1/assets/%s/%s", strings.TrimRight(p.PublicAPIURL, "/"), url.PathEscape(projectID), url.PathEscape(hash))
}

// Process handles one batch as received from an SDK.
//
// What is stored depends on the batch's data mode (Recording API v1.2 §4):
//
//	masked (or v1 device_masked): one copy, masked; no unmasked view
//	raw: a raw copy and a server-built masked copy
//	none given (older web SDKs): raw + masked, as before
//
// The always-masked rules (secrets, card numbers) apply to every copy.
func (p *Processor) Process(ctx context.Context, batch models.EventBatch) error {
	for i := range batch.Events {
		masking.ApplyAlways(&batch.Events[i])
	}
	mode := batch.DataMode
	if mode == "" && batch.DeviceMasked {
		mode = "masked"
	}

	var masked *models.EventBatch
	if transform.NeedsTransform(&batch) {
		// Keep what the SDK sent: the conversion can be improved and re-run.
		if p.MinIO != nil {
			if _, err := p.MinIO.StoreNativeEvents(ctx, batch.SessionID, &batch); err != nil {
				return fmt.Errorf("store native copy: %w", err)
			}
		}
		project := batch.ProjectID
		opt := transform.Options{
			AssetURL: func(hash string) string { return p.AssetURL(project, hash) },
			MaskText: func(s string) string { return masking.MaskText(s, p.Masking) },
		}
		if mode == "raw" {
			// Raw copy: as recorded (card numbers still redacted); masked copy
			// built here: flagged nodes and screenshot areas hidden.
			maskedOpt := opt
			maskedOpt.MaskNodes = true
			m := batch
			m.Events = transform.Events(batch.Events, maskedOpt)
			m.DeviceMasked = false
			masked = maskCopy(&m, p.Masking)
			rawOpt := opt
			rawOpt.MaskText = masking.RedactCards
			batch.Events = transform.Events(batch.Events, rawOpt)
			batch.DeviceMasked = false
		} else {
			batch.Events = transform.Events(batch.Events, opt)
			batch.DeviceMasked = true
			batch = *maskCopy(&batch, p.Masking)
		}
	} else {
		switch mode {
		case "masked":
			// Web, masked mode: only the masked copy is kept.
			batch = *masking.MaskBatch(p.Tracker, &batch, p.Masking)
			batch = *maskCopy(&batch, p.Masking)
			batch.DeviceMasked = true
		default:
			masked = maskCopy(masking.MaskBatch(p.Tracker, &batch, p.Masking), p.Masking)
		}
	}

	if p.Publisher != nil {
		if err := PublishBatch(p.Publisher, kafka.TopicEventsRaw, &batch); err != nil {
			return fmt.Errorf("publish events.raw: %w", err)
		}
		if masked != nil {
			if err := PublishBatch(p.Publisher, kafka.TopicEventsMasked, masked); err != nil {
				return fmt.Errorf("publish events.masked: %w", err)
			}
		}
		return nil
	}
	if _, err := p.MinIO.StoreEvents(ctx, batch.SessionID, &batch); err != nil {
		return fmt.Errorf("store events: %w", err)
	}
	if masked != nil {
		if _, err := p.MinIO.StoreMaskedEvents(ctx, batch.SessionID, masked); err != nil {
			return fmt.Errorf("store masked events: %w", err)
		}
	}
	return nil
}

// maskCopy applies the text masking of a masked copy: free-text fields,
// network headers and bodies, console arguments.
func maskCopy(b *models.EventBatch, cfg masking.Config) *models.EventBatch {
	out := masking.MaskTextFields(b, cfg)
	for i := range out.Events {
		masking.ScrubNetworkConsole(&out.Events[i], cfg)
	}
	return out
}
