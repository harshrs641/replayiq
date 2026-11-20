// Package transform turns what SDKs record into rrweb events, the one
// format storage, replay and the AI work with. Web batches are rrweb
// already and pass through; mobile batches carry screenshots (v1 `screen`
// / `touch`) or a Native DOM (v1.1 `ui_snapshot` / `ui_mutation`). See
// docs/sdk/recording-api-v1.md and recording-api-v1.1-native-dom.md.
package transform

import (
	"log/slog"

	"github.com/harshrs641/replayiq/internal/models"
)

// Options configure a conversion.
type Options struct {
	// AssetURL returns where the player loads an uploaded asset (image,
	// island, font) from, given its hash.
	AssetURL func(hash string) string
	// MaskText redacts PII patterns in UI text (labels, text nodes).
	MaskText func(string) string
}

// NeedsTransform reports whether a batch has mobile events to convert.
func NeedsTransform(b *models.EventBatch) bool {
	for _, e := range b.Events {
		if e.Type == 5 {
			switch e.Subtype {
			case "screen", "touch", "ui_snapshot", "ui_mutation":
				return true
			}
		}
	}
	return false
}

// Events converts a batch's mobile events to rrweb and passes every other
// event through. A malformed native event is dropped (and logged), not the
// whole batch.
func Events(events []models.RRWebEvent, opt Options) []models.RRWebEvent {
	out := make([]models.RRWebEvent, 0, len(events)+4)
	var screens []models.RRWebEvent
	flushScreens := func() {
		if len(screens) > 0 {
			out = append(out, convertScreens(screens)...)
			screens = screens[:0]
		}
	}
	for _, e := range events {
		if e.Type == 5 && (e.Subtype == "ui_snapshot" || e.Subtype == "ui_mutation") {
			flushScreens()
			c := &converter{opt: opt}
			var conv []models.RRWebEvent
			var err error
			if e.Subtype == "ui_snapshot" {
				conv, err = c.convertSnapshot(e)
			} else {
				conv, err = c.convertMutation(e)
			}
			if err != nil {
				slog.Warn("dropping malformed native DOM event", "subtype", e.Subtype, "error", err)
				continue
			}
			out = append(out, conv...)
			continue
		}
		screens = append(screens, e)
	}
	flushScreens()
	return out
}
