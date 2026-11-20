package transform

import (
	"fmt"

	"github.com/harshrs641/replayiq/internal/models"
)

// Mobile SDKs (recording API v1) send screenshots ("screen") and touches
// ("touch") as Custom events. They are turned into rrweb events here, so the
// web player, the replay index (keyframes) and seeking work unchanged:
//
//	screen, keyframe   -> Meta + FullSnapshot of a one-image page
//	screen, otherwise  -> a mutation swapping that image's src (no flash)
//	touch              -> rrweb touch interaction on the image
//
// Every frame page uses the same node ids, so the conversion needs no state
// across batches: the SDK says which frames are keyframes.

const (
	rrFullSnapshot = 2
	rrIncremental  = 3
	rrMeta         = 4

	srcMutation         = 0
	srcMouseInteraction = 2
	srcTouchMove        = 6
	touchStart          = 7
	touchEnd            = 9

	// Node ids of the frame page (the same as Mixpanel's Android/Flutter
	// SDKs use, so frames from either replay alike).
	nodeDocument = 1
	nodeDoctype  = 2
	nodeHTML     = 3
	nodeHead     = 4
	nodeStyle    = 17
	nodeBody     = 25
	nodeImage    = 28
	nodeScreen   = 29
)

const frameCSS = "body { margin: 0px; padding: 0px; } .screen img { width: 100%; height: auto; display: block; }"

// hasScreenFrames reports whether a batch carries mobile screenshots.
func HasScreenFrames(b *models.EventBatch) bool {
	for _, e := range b.Events {
		if e.Type == 5 && e.Subtype == "screen" {
			return true
		}
	}
	return false
}

// convertMobileEvents rewrites screen/touch events into rrweb events and
// passes every other event through.
func convertScreens(events []models.RRWebEvent) []models.RRWebEvent {
	out := make([]models.RRWebEvent, 0, len(events)+4)
	for _, e := range events {
		if e.Type != 5 {
			out = append(out, e)
			continue
		}
		switch e.Subtype {
		case "screen":
			if e.Image == "" {
				continue
			}
			if e.Keyframe {
				out = append(out,
					models.RRWebEvent{Type: rrMeta, Timestamp: e.Timestamp, Data: map[string]any{
						"width": e.Width, "height": e.Height,
					}},
					models.RRWebEvent{Type: rrFullSnapshot, Timestamp: e.Timestamp, Data: map[string]any{
						"node":          framePage(e.Image),
						"initialOffset": map[string]any{"top": 0, "left": 0},
					}},
				)
			} else {
				out = append(out, models.RRWebEvent{Type: rrIncremental, Timestamp: e.Timestamp, Data: map[string]any{
					"source":     srcMutation,
					"texts":      []any{},
					"attributes": []any{map[string]any{"id": nodeImage, "attributes": map[string]any{"src": e.Image}}},
					"removes":    []any{},
					"adds":       []any{},
				}})
			}
		case "touch":
			x, y := int(e.X), int(e.Y)
			switch e.Phase {
			case "down", "up":
				kind := touchStart
				if e.Phase == "up" {
					kind = touchEnd
				}
				out = append(out, models.RRWebEvent{Type: rrIncremental, Timestamp: e.Timestamp, Data: map[string]any{
					"source": srcMouseInteraction, "type": kind, "id": nodeImage, "x": x, "y": y,
				}})
			case "move":
				out = append(out, models.RRWebEvent{Type: rrIncremental, Timestamp: e.Timestamp, Data: map[string]any{
					"source":    srcTouchMove,
					"positions": []any{map[string]any{"x": x, "y": y, "id": nodeImage, "timeOffset": 0}},
				}})
			}
		default:
			out = append(out, e)
		}
	}
	return out
}

// framePage is the rrweb snapshot of a page showing one screenshot.
func framePage(image string) map[string]any {
	el := func(id int, tag string, attrs map[string]any, children ...any) map[string]any {
		if children == nil {
			children = []any{}
		}
		return map[string]any{"type": 2, "id": id, "tagName": tag, "attributes": attrs, "childNodes": children}
	}
	return map[string]any{
		"type": 0, "id": nodeDocument,
		"childNodes": []any{
			map[string]any{"type": 1, "id": nodeDoctype, "name": "html", "publicId": "", "systemId": ""},
			el(nodeHTML, "html", map[string]any{},
				// rrweb rebuilds a <style> from its _cssText attribute.
				el(nodeHead, "head", map[string]any{},
					el(nodeStyle, "style", map[string]any{"_cssText": frameCSS})),
				el(nodeBody, "body", map[string]any{},
					el(nodeScreen, "div", map[string]any{"class": "screen"},
						el(nodeImage, "img", map[string]any{"src": image})))),
		},
	}
}

// validateScreenBatch: screenshots can only be masked on the device.
func ValidateScreenBatch(b *models.EventBatch) error {
	if !b.DeviceMasked {
		return fmt.Errorf("batches with screen frames must set device_masked: the server cannot mask pixels")
	}
	return nil
}
