package ingest

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/harshrs641/replayiq/internal/kafka"
	"github.com/harshrs641/replayiq/internal/masking"
	"github.com/harshrs641/replayiq/internal/models"
)

type fakePublisher struct {
	sent map[string][]*models.EventBatch
}

func (f *fakePublisher) Publish(topic, key string, v any) error {
	if f.sent == nil {
		f.sent = map[string][]*models.EventBatch{}
	}
	b := v.(*models.EventBatch)
	f.sent[topic] = append(f.sent[topic], b)
	return nil
}

func TestProcessConvertsMobileAndMasksWeb(t *testing.T) {
	pub := &fakePublisher{}
	p := &Processor{Masking: masking.DefaultConfig(nil), Tracker: masking.NewTracker(), Publisher: pub, PublicAPIURL: "https://api.test/"}

	var mobile models.EventBatch
	json.Unmarshal([]byte(`{"session_id":"m1","project_id":"acme app","device_masked":true,"events":[
	  {"type":5,"subtype":"ui_snapshot","timestamp":1,"width":390,"height":844,
	   "root":{"id":1,"k":"view","f":[0,0,390,844],"c":[{"id":2,"k":"image","f":[0,0,10,10],"img":{"a":"`+strings.Repeat("a", 64)+`"}},
	                                                 {"id":3,"k":"text","f":[0,20,300,20],"tx":{"v":"Mail jane@acme.com"}}]}},
	  {"type":5,"subtype":"console","level":"log","message":"user jane@acme.com","timestamp":2}]}`), &mobile)
	if err := p.Process(context.Background(), mobile); err != nil {
		t.Fatal(err)
	}
	raw := pub.sent[kafka.TopicEventsRaw]
	if len(raw) != 1 || len(pub.sent[kafka.TopicEventsMasked]) != 0 {
		t.Fatalf("device-masked: one copy only, got raw=%d masked=%d", len(raw), len(pub.sent[kafka.TopicEventsMasked]))
	}
	out, _ := json.Marshal(raw[0])
	s := string(out)
	if !strings.Contains(s, `"type":2`) || strings.Contains(s, "ui_snapshot") {
		t.Fatalf("snapshot not converted: %.300s", s)
	}
	if !strings.Contains(s, "https://api.test/api/v1/assets/acme%20app/"+strings.Repeat("a", 64)) {
		t.Fatalf("asset URL missing: %.600s", s)
	}
	if strings.Contains(s, "jane@acme.com") {
		t.Fatal("PII left in UI text or console message")
	}

	var web models.EventBatch
	json.Unmarshal([]byte(`{"session_id":"w1","project_id":"acme","events":[{"type":5,"subtype":"click","selector":"button#pay","timestamp":1}]}`), &web)
	if err := p.Process(context.Background(), web); err != nil {
		t.Fatal(err)
	}
	if len(pub.sent[kafka.TopicEventsRaw]) != 2 || len(pub.sent[kafka.TopicEventsMasked]) != 1 {
		t.Fatal("web batches get a raw and a masked copy")
	}
}

func TestRawModeKeepsRawAndMaskedCopiesApart(t *testing.T) {
	pub := &fakePublisher{}
	p := &Processor{Masking: masking.DefaultConfig(nil), Tracker: masking.NewTracker(), Publisher: pub, PublicAPIURL: "https://api.test"}
	var b models.EventBatch
	json.Unmarshal([]byte(`{"session_id":"r1","project_id":"acme","data_mode":"raw","events":[
	  {"type":5,"subtype":"ui_snapshot","timestamp":1,"width":10,"height":10,
	   "root":{"id":1,"k":"view","f":[0,0,10,10],"c":[{"id":2,"k":"input","f":[0,0,10,5],"in":{"type":"email","v":"jane@acme.com"}}]}},
	  {"type":5,"subtype":"network","timestamp":2,"method":"POST","url":"https://api.test/x",
	   "request":{"headers":{"authorization":"Bearer S","x-user":"jane@acme.com"},"body":"{\"password\":\"p\",\"email\":\"jane@acme.com\"}"}}]}`), &b)
	if err := p.Process(context.Background(), b); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(pub.sent[kafka.TopicEventsRaw][0])
	masked, _ := json.Marshal(pub.sent[kafka.TopicEventsMasked][0])
	if !strings.Contains(string(raw), "jane@acme.com") {
		t.Fatalf("raw copy must keep the recorded values: %s", raw)
	}
	if strings.Contains(string(masked), "jane@acme.com") {
		t.Fatalf("masked copy leaked: %s", masked)
	}
	for _, copy := range []string{string(raw), string(masked)} {
		if strings.Contains(copy, "Bearer S") || strings.Contains(copy, `\"p\"`) {
			t.Fatalf("always-masked data stored: %s", copy)
		}
	}
	if pub.sent[kafka.TopicEventsRaw][0].DeviceMasked {
		t.Fatal("raw sessions are not device-masked: the dashboard offers both views")
	}
}

func TestWebMaskedModeStoresOneCopy(t *testing.T) {
	pub := &fakePublisher{}
	p := &Processor{Masking: masking.DefaultConfig(nil), Tracker: masking.NewTracker(), Publisher: pub}
	var b models.EventBatch
	json.Unmarshal([]byte(`{"session_id":"w2","project_id":"acme","data_mode":"masked","events":[{"type":5,"subtype":"console","level":"info","message":"hi jane@acme.com","timestamp":1}]}`), &b)
	p.Process(context.Background(), b)
	if len(pub.sent[kafka.TopicEventsMasked]) != 0 || len(pub.sent[kafka.TopicEventsRaw]) != 1 {
		t.Fatal("masked mode: one copy only")
	}
	out, _ := json.Marshal(pub.sent[kafka.TopicEventsRaw][0])
	if strings.Contains(string(out), "jane@acme.com") || !pub.sent[kafka.TopicEventsRaw][0].DeviceMasked {
		t.Fatalf("the one copy is the masked one: %s", out)
	}
}
