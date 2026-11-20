package models

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestCustomEventKeepsUnknownFields(t *testing.T) {
	in := `{"type":5,"timestamp":7,"subtype":"jank","screen":"/checkout","dropped":12,"root":{"id":1,"k":"view"}}`
	var e RRWebEvent
	if err := json.Unmarshal([]byte(in), &e); err != nil {
		t.Fatal(err)
	}
	if e.Subtype != "jank" || string(e.Extra["dropped"]) != "12" || e.Extra["subtype"] != nil {
		t.Fatalf("%+v", e)
	}
	out, _ := json.Marshal(e)
	var back map[string]any
	if err := json.Unmarshal(out, &back); err != nil {
		t.Fatalf("%s: %v", out, err)
	}
	if back["screen"] != "/checkout" || back["dropped"] != float64(12) || back["subtype"] != "jank" ||
		back["root"].(map[string]any)["k"] != "view" {
		t.Fatalf("round trip lost fields: %s", out)
	}
}

func TestNonCustomEventsIgnoreUnknownFields(t *testing.T) {
	var e RRWebEvent
	json.Unmarshal([]byte(`{"type":3,"timestamp":1,"data":{"source":0},"weird":1}`), &e)
	out, _ := json.Marshal(e)
	if e.Extra != nil || strings.Contains(string(out), "weird") {
		t.Fatalf("%s", out)
	}
	// Slices of events (batches) use the same methods.
	var b EventBatch
	json.Unmarshal([]byte(`{"events":[{"type":5,"timestamp":1,"subtype":"lifecycle","state":"background"}]}`), &b)
	out, _ = json.Marshal(b)
	if !strings.Contains(string(out), `"state":"background"`) {
		t.Fatalf("%s", out)
	}
}

func TestBatchDropsOnlyMalformedEvents(t *testing.T) {
	var b EventBatch
	err := json.Unmarshal([]byte(`{"session_id":"s","batch_id":"b1","events":[
	  {"type":5,"subtype":"click","timestamp":1},
	  {"type":"wifi","subtype":"connectivity","timestamp":2},
	  {"type":5,"subtype":"lifecycle","state":"background","timestamp":3}]}`), &b)
	if err != nil || b.SessionID != "s" || b.BatchID != "b1" || len(b.Events) != 2 || b.Dropped != 1 {
		t.Fatalf("err=%v batch=%+v", err, b)
	}
	if string(b.Events[1].Extra["state"]) != `"background"` {
		t.Fatal("extra fields lost")
	}
	if json.Unmarshal([]byte(`{"session_id":`), &b) == nil {
		t.Fatal("a broken body must still fail")
	}
}
