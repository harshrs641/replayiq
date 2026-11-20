package transform

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/harshrs641/replayiq/internal/models"
)

func event(t *testing.T, js string) models.RRWebEvent {
	t.Helper()
	var e models.RRWebEvent
	if err := json.Unmarshal([]byte(js), &e); err != nil {
		t.Fatal(err)
	}
	return e
}

var testOpt = Options{
	AssetURL: func(h string) string { return "https://riq.test/api/v1/assets/p/" + h },
	MaskText: func(s string) string { return strings.ReplaceAll(s, "jane@acme.com", "[email]") },
}

const snapshotJSON = `{"type":5,"subtype":"ui_snapshot","timestamp":1000,"width":393,"height":852,"bg":"#FFF9FAFB",
 "fonts":[{"family":"Inter","w":600,"a":"f0"}],
 "root":{"id":1,"k":"view","f":[0,0,393,852],"c":[
   {"id":2,"k":"text","f":[16,60,361,30],"tx":{"v":"Hi jane@acme.com","font":"Inter","size":17,"w":600,"col":"#FF111827","ml":1}},
   {"id":3,"k":"view","f":[16,120,361,56],"role":"button","label":"Pay now",
    "s":{"bg":"#FF1F2937","r":[12,12,12,12],"bw":1,"bc":"#80E5E7EB","sh":[0,2,8,0,"#33000000"],"o":0.5,"t":[1,0,0,1,4,0],"clip":true,
         "grad":{"type":"linear","angle":90,"stops":[["#FFFF0000",0],["#FF0000FF",1]]}},
    "c":[{"id":4,"k":"text","f":[0,0,361,56],"tx":{"v":"Pay now","al":"center"}}]},
   {"id":5,"k":"image","f":[16,200,64,64],"img":{"a":"abc123","fit":"cover"}},
   {"id":6,"k":"input","f":[16,280,361,44],"in":{"type":"text","ph":"Card number","len":16,"focus":true}},
   {"id":7,"k":"mask","f":[16,340,361,44]},
   {"id":8,"k":"scroll","f":[0,400,393,452],"so":[0,240],"c":[{"id":9,"k":"text","f":[16,0,361,20],"tx":{"v":"Item 1"}}]}
 ]}}`

func TestSnapshotToRRWeb(t *testing.T) {
	out := Events([]models.RRWebEvent{event(t, snapshotJSON)}, testOpt)
	if len(out) != 3 || out[0].Type != 4 || out[1].Type != 2 || out[2].Type != 3 {
		t.Fatalf("want Meta, FullSnapshot, Scroll; got %d events", len(out))
	}
	if out[0].Data["width"] != float64(393) {
		t.Fatalf("meta %+v", out[0].Data)
	}
	page := fmtJSON(out[1].Data["node"])
	for _, want := range []string{
		`@font-face{font-family:\"Inter\";font-weight:600;src:url(\"https://riq.test/api/v1/assets/p/f0\");}`,
		`"textContent":"Hi [email]"`, // UI text is masked
		`left:16px;top:120px;width:361px;height:56px;`,
		`background-color:rgb(31,41,55);`,
		`background-image:linear-gradient(90deg,rgb(255,0,0) 0%,rgb(0,0,255) 100%);`,
		`border-radius:12px 12px 12px 12px;`,
		`border:1px solid rgba(229,231,235,0.5)`,
		`box-shadow:0px 2px 8px 0px rgba(0,0,0,0.2)`,
		`opacity:0.5;`, `transform:matrix(1,0,0,1,4,0);`, `overflow:hidden;`,
		`"aria-label":"Pay now"`, `"data-role":"button"`,
		`"tagName":"img"`, `"src":"https://riq.test/api/v1/assets/p/abc123"`, `object-fit:cover;`,
		`"textContent":"••••••••••••••••"`, `outline:2px solid`, // input: never the value
		`repeating-linear-gradient(45deg`, // mask
		`white-space:pre;`, `font-family:\"Inter\",-apple-system`,
		`background:rgb(249,250,251);`,
	} {
		if !strings.Contains(page, want) {
			t.Errorf("snapshot lacks %s", want)
		}
	}
	if strings.Contains(page, "jane@acme.com") {
		t.Fatal("unmasked email in replay")
	}
	if out[2].Data["source"] != srcScroll || out[2].Data["id"] != elemID(8) || out[2].Data["y"] != float64(240) {
		t.Fatalf("scroll %+v", out[2].Data)
	}
	// rrweb ids must be unique.
	seen := map[float64]bool{}
	var walk func(any)
	walk = func(v any) {
		m, ok := v.(map[string]any)
		if !ok {
			return
		}
		if id, ok := m["id"].(float64); ok {
			if seen[id] {
				t.Fatalf("duplicate rrweb id %v", id)
			}
			seen[id] = true
		}
		kids, _ := m["childNodes"].([]any)
		for _, c := range kids {
			walk(c)
		}
	}
	var tree map[string]any
	json.Unmarshal([]byte(page), &tree)
	walk(tree)
	if len(seen) < 15 {
		t.Fatalf("only %d nodes", len(seen))
	}
}

func TestMutationToRRWeb(t *testing.T) {
	e := event(t, `{"type":5,"subtype":"ui_mutation","timestamp":2000,
	 "adds":[{"p":1,"next":5,"n":{"id":20,"k":"text","f":[0,0,10,10],"tx":{"v":"New"}}},{"p":0,"n":{"id":21,"k":"view","f":[0,0,1,1],
	          "c":[{"id":22,"k":"view","f":[0,0,1,1],"c":[{"id":23,"k":"text","f":[0,0,1,1],"tx":{"v":"Deep"}}]}]}}],
	 "removes":[{"p":1,"id":7}],
	 "updates":[{"id":2,"k":"text","f":[16,64,361,30],"tx":{"v":"Bye","size":17}},
	            {"id":5,"k":"image","f":[16,200,64,64],"img":{"a":"def456","fit":"cover"}},
	            {"id":8,"k":"scroll","f":[0,400,393,452],"so":[0,600]}]}`)
	out := Events([]models.RRWebEvent{e}, testOpt)
	if len(out) != 2 || out[0].Type != 3 || out[1].Data["source"] != srcScroll {
		t.Fatalf("want mutation + scroll, got %d", len(out))
	}
	d := fmtJSON(out[0].Data)
	for _, want := range []string{
		`"removes":[{"id":1028,"parentId":1004}]`,
		`{"nextId":1020,"node":`, `"parentId":1004`, // add before sibling 5 under node 1
		`"nextId":null`, `"parentId":28`, // p=0 → the screen container
		`"texts":[{"id":1009,"value":"Bye"}]`,
		`"src":"https://riq.test/api/v1/assets/p/def456"`,
		`top:64px;`,
		// subtrees are flattened, parents first, each with no children
		`{"nextId":null,"node":{"attributes":{"style":"position:absolute;left:0px;top:0px;width:1px;height:1px;"},"childNodes":[],"id":1088,"tagName":"div","type":2},"parentId":1084}`,
		`{"nextId":null,"node":{"id":1093,"textContent":"Deep","type":3},"parentId":1092}`,
	} {
		if !strings.Contains(d, want) {
			t.Errorf("mutation lacks %s\n%s", want, d)
		}
	}
	if out[1].Data["y"] != float64(600) {
		t.Fatalf("scroll %+v", out[1].Data)
	}
}

func TestMalformedNativeEventIsDroppedNotTheBatch(t *testing.T) {
	bad := event(t, `{"type":5,"subtype":"ui_snapshot","timestamp":1,"root":"nope"}`)
	ok := event(t, `{"type":5,"subtype":"click","selector":"button:\"Pay\"","timestamp":2}`)
	out := Events([]models.RRWebEvent{bad, ok}, testOpt)
	if len(out) != 1 || out[0].Subtype != "click" {
		t.Fatalf("%+v", out)
	}
}

func TestColor(t *testing.T) {
	for in, want := range map[string]string{
		"#FF102030": "rgb(16,32,48)", "#102030": "rgb(16,32,48)", "#00000000": "rgba(0,0,0,0)",
		"#80FFFFFF": "rgba(255,255,255,0.5)", "nope": "transparent", "": "transparent",
	} {
		if got := color(in); got != want {
			t.Errorf("%s: %s want %s", in, got, want)
		}
	}
}

func TestNeedsTransform(t *testing.T) {
	web := &models.EventBatch{Events: []models.RRWebEvent{{Type: 3}, {Type: 5, Subtype: "click"}}}
	mobile := &models.EventBatch{Events: []models.RRWebEvent{{Type: 5, Subtype: "ui_mutation"}}}
	if NeedsTransform(web) || !NeedsTransform(mobile) {
		t.Fatal("NeedsTransform")
	}
}

func TestTextIsNotClippedAndTouchesHitTheScreen(t *testing.T) {
	out := Events([]models.RRWebEvent{event(t, snapshotJSON),
		event(t, `{"type":5,"subtype":"touch","timestamp":1500,"x":100,"y":200,"phase":"down"}`)}, testOpt)
	page := fmtJSON(out[1].Data["node"])
	if strings.Contains(page, "-webkit-line-clamp:1") {
		t.Fatal("single-line text must not be clamped")
	}
	if !strings.Contains(page, `"id":28,"tagName":"div"`) {
		t.Fatalf("screen container must have the touch target id")
	}
	last := out[len(out)-1]
	if last.Data["id"] != nodeImage {
		t.Fatalf("touch target %+v", last.Data)
	}
}

func TestImagesAreAlwaysImgSoLateAssetsShow(t *testing.T) {
	snap := Events([]models.RRWebEvent{event(t, `{"type":5,"subtype":"ui_snapshot","timestamp":1,"width":10,"height":10,
	  "root":{"id":1,"k":"view","f":[0,0,10,10],"c":[{"id":2,"k":"image","f":[0,0,5,5]},{"id":3,"k":"island","f":[0,0,10,10],"hint":"map"}]}}`)}, testOpt)
	page := fmtJSON(snap[1].Data["node"])
	if strings.Count(page, `"tagName":"img"`) != 2 || !strings.Contains(page, blankImage) || !strings.Contains(page, `"title":"map"`) {
		t.Fatalf("%s", page)
	}
	// The asset arrives later: an update sets the src of that same <img>.
	mut := Events([]models.RRWebEvent{event(t, `{"type":5,"subtype":"ui_mutation","timestamp":2,
	  "updates":[{"id":2,"k":"image","f":[0,0,5,5],"img":{"a":"abc"}}]}`)}, testOpt)
	if !strings.Contains(fmtJSON(mut[0].Data), `"src":"https://riq.test/api/v1/assets/p/abc"`) {
		t.Fatalf("%s", fmtJSON(mut[0].Data))
	}
}
