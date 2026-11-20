package transform

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/harshrs641/replayiq/internal/models"
)

func TestConvertMobileEvents(t *testing.T) {
	in := []models.RRWebEvent{
		{Type: 5, Subtype: "navigate", URL: "app://com.acme/checkout", Timestamp: 1},
		{Type: 5, Subtype: "screen", Timestamp: 10, Width: 393, Height: 852, Image: "data:image/jpeg;base64,AAA", Keyframe: true},
		{Type: 5, Subtype: "screen", Timestamp: 20, Width: 393, Height: 852, Image: "data:image/jpeg;base64,BBB"},
		{Type: 5, Subtype: "touch", Timestamp: 30, X: 196.6, Y: 610, Phase: "down"},
		{Type: 5, Subtype: "touch", Timestamp: 35, X: 197, Y: 600, Phase: "move"},
		{Type: 5, Subtype: "touch", Timestamp: 40, X: 196, Y: 610, Phase: "up"},
		{Type: 5, Subtype: "screen", Timestamp: 50}, // no image: dropped
		{Type: 5, Subtype: "click", Selector: `button:"Pay now"`, Timestamp: 41},
	}
	out := convertScreens(in, Options{})
	types := make([]int, len(out))
	for i, e := range out {
		types[i] = e.Type
	}
	want := []int{5, 4, 2, 3, 3, 3, 3, 5}
	if len(types) != len(want) {
		t.Fatalf("types %v want %v", types, want)
	}
	for i := range want {
		if types[i] != want[i] {
			t.Fatalf("types %v want %v", types, want)
		}
	}
	if out[1].Data["width"] != float64(393) || out[1].Timestamp != 10 {
		t.Fatalf("meta %+v", out[1])
	}
	page := out[2].Data["node"].(map[string]any)
	if !strings.Contains(fmtJSON(page), `"src":"data:image/jpeg;base64,AAA"`) {
		t.Fatalf("keyframe page lacks the image: %s", fmtJSON(page))
	}
	attrs := out[3].Data["attributes"].([]any)[0].(map[string]any)
	if attrs["id"] != nodeImage || attrs["attributes"].(map[string]any)["src"] != "data:image/jpeg;base64,BBB" {
		t.Fatalf("frame swap %+v", out[3].Data)
	}
	if out[4].Data["type"] != touchStart || out[4].Data["x"] != 196 || out[6].Data["type"] != touchEnd {
		t.Fatalf("touches %+v %+v", out[4].Data, out[6].Data)
	}
	if out[5].Data["source"] != srcTouchMove {
		t.Fatalf("move %+v", out[5].Data)
	}
	if out[7].Subtype != "click" || out[0].Subtype != "navigate" {
		t.Fatal("app events must pass through")
	}
}

func TestScreenBatchesMustBeDeviceMasked(t *testing.T) {
	b := &models.EventBatch{Events: []models.RRWebEvent{{Type: 5, Subtype: "screen", Image: "x"}}}
	if !HasScreenFrames(b) || ValidateScreenBatch(b) == nil {
		t.Fatal("unmasked screenshots must be rejected")
	}
	b.DeviceMasked = true
	if ValidateScreenBatch(b) != nil {
		t.Fatal("device-masked screenshots are fine")
	}
}

func fmtJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}
