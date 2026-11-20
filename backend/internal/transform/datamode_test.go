package transform

import (
	"bytes"
	"encoding/base64"
	"image"
	"image/png"
	"strings"
	"testing"

	"github.com/harshrs641/replayiq/internal/models"
)

const rawSnapshot = `{"type":5,"subtype":"ui_snapshot","timestamp":1,"width":100,"height":100,
 "root":{"id":1,"k":"view","f":[0,0,100,100],"c":[
   {"id":2,"k":"input","f":[0,0,100,20],"in":{"type":"text","ph":"Name","len":4,"v":"Jane"}},
   {"id":3,"k":"input","f":[0,20,100,20],"in":{"type":"password","len":0,"v":"hunter2"}},
   {"id":4,"k":"text","f":[0,40,100,20],"masked":true,"tx":{"v":"IBAN DE89 3704"}}]}}`

func TestRawCopyShowsValuesMaskedCopyHidesThem(t *testing.T) {
	raw := fmtJSON(Events([]models.RRWebEvent{event(t, rawSnapshot)}, Options{})[1].Data["node"])
	if !strings.Contains(raw, `"textContent":"Jane"`) || !strings.Contains(raw, "IBAN DE89 3704") {
		t.Fatalf("raw copy: %s", raw)
	}
	if strings.Contains(raw, "hunter2") {
		t.Fatal("password values never shown, even raw")
	}
	masked := fmtJSON(Events([]models.RRWebEvent{event(t, rawSnapshot)}, Options{MaskNodes: true})[1].Data["node"])
	for _, leak := range []string{"Jane", "IBAN", "hunter2"} {
		if strings.Contains(masked, leak) {
			t.Fatalf("masked copy leaked %s: %s", leak, masked)
		}
	}
	if !strings.Contains(masked, "repeating-linear-gradient(45deg") || !strings.Contains(masked, "••••") {
		t.Fatalf("masked copy needs a mask block and input dots: %s", masked)
	}
}

func TestMaskedCopyPaintsScreenshotMaskRects(t *testing.T) {
	src := image.NewRGBA(image.Rect(0, 0, 200, 200)) // 2x a 100x100 pt screen, white
	for i := range src.Pix {
		src.Pix[i] = 0xff
	}
	var b bytes.Buffer
	png.Encode(&b, src)
	img := "data:image/png;base64," + base64.StdEncoding.EncodeToString(b.Bytes())
	e := event(t, `{"type":5,"subtype":"screen","timestamp":1,"width":100,"height":100,"keyframe":true,
	  "image":"`+img+`","mask_rects":[[10,10,20,20]]}`)

	if got := Events([]models.RRWebEvent{e}, Options{}); !strings.Contains(fmtJSON(got[1].Data["node"]), img) {
		t.Fatal("raw copy keeps the frame as sent")
	}
	out := Events([]models.RRWebEvent{e}, Options{MaskNodes: true})
	page := fmtJSON(out[1].Data["node"])
	i := strings.Index(page, "data:image/jpeg;base64,")
	if i < 0 {
		t.Fatalf("masked frame not re-encoded: %.200s", page)
	}
	enc := page[i+len("data:image/jpeg;base64,"):]
	enc = enc[:strings.IndexByte(enc, '"')]
	data, _ := base64.StdEncoding.DecodeString(enc)
	m, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	r, g, bl, _ := m.At(40, 40).RGBA() // inside the rect (scaled 2x)
	if r>>8 > 0xb0 || g>>8 > 0xb0 || bl>>8 > 0xc0 {
		t.Fatalf("masked area not painted: %x %x %x", r>>8, g>>8, bl>>8)
	}
	r, _, _, _ = m.At(150, 150).RGBA()
	if r>>8 < 0xf0 {
		t.Fatal("unmasked area changed")
	}
}
