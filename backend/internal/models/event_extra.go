package models

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"sync"
)

// Custom events (type 5) carry fields RRWebEvent doesn't name: the Native
// DOM tree and its changes (root, adds, ...), and mobile signals (kind,
// state, dropped, ...; see docs/sdk/recording-api-v1.1-native-dom.md).
// They are kept in Extra and written back out unchanged, so new event
// types pass through ingest, Kafka and storage without a struct change.
// Other event types (the bulk of web DOM data) decode as before.

var (
	knownFieldsOnce sync.Once
	knownFields     map[string]bool
)

func eventFieldNames() map[string]bool {
	knownFieldsOnce.Do(func() {
		knownFields = map[string]bool{}
		t := reflect.TypeOf(RRWebEvent{})
		for i := 0; i < t.NumField(); i++ {
			name, _, _ := strings.Cut(t.Field(i).Tag.Get("json"), ",")
			if name != "" && name != "-" {
				knownFields[name] = true
			}
		}
	})
	return knownFields
}

func (e *RRWebEvent) UnmarshalJSON(b []byte) error {
	type plain RRWebEvent
	if err := json.Unmarshal(b, (*plain)(e)); err != nil {
		return err
	}
	e.Extra = nil
	if e.Type != 5 {
		return nil
	}
	var all map[string]json.RawMessage
	if err := json.Unmarshal(b, &all); err != nil {
		return err
	}
	known := eventFieldNames()
	for k := range all {
		if known[k] {
			delete(all, k)
		}
	}
	if len(all) > 0 {
		e.Extra = all
	}
	return nil
}

func (e RRWebEvent) MarshalJSON() ([]byte, error) {
	type plain RRWebEvent
	b, err := json.Marshal(plain(e))
	if err != nil || len(e.Extra) == 0 {
		return b, err
	}
	extra, err := json.Marshal(e.Extra)
	if err != nil {
		return nil, err
	}
	// Both are objects: splice extra's fields into b.
	var buf bytes.Buffer
	buf.Grow(len(b) + len(extra))
	buf.Write(b[:len(b)-1])
	if len(b) > 2 {
		buf.WriteByte(',')
	}
	buf.Write(extra[1:])
	return buf.Bytes(), nil
}

// UnmarshalJSON decodes a batch event by event: an event that doesn't fit
// the schema (e.g. a signal field named like a reserved one) is skipped and
// counted in Dropped, instead of failing every other event in the batch.
func (b *EventBatch) UnmarshalJSON(data []byte) error {
	type plain EventBatch
	var raw struct {
		*plain
		Events []json.RawMessage `json:"events"`
	}
	raw.plain = (*plain)(b)
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	b.Events = make([]RRWebEvent, 0, len(raw.Events))
	b.Dropped = 0
	for _, r := range raw.Events {
		var e RRWebEvent
		if err := json.Unmarshal(r, &e); err != nil {
			b.Dropped++
			continue
		}
		b.Events = append(b.Events, e)
	}
	return nil
}
