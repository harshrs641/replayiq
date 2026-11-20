package transform

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"image"
	imgcolor "image/color"
	"image/draw"
	"image/jpeg"
	"image/png"
	"strings"

	"github.com/harshrs641/replayiq/internal/models"
)

// maskFill is the colour painted over masked areas of a raw screenshot in
// its masked copy.
var maskFill = imgcolor.RGBA{0x9c, 0xa3, 0xaf, 0xff}

// paintMaskRects returns the screen event's image with its mask_rects
// (logical points, v1.2 raw recordings) painted over. When the frame has no
// rects it is returned as is; when it can't be decoded, a blank frame is
// returned instead: the masked copy must never show unmasked pixels.
func paintMaskRects(e models.RRWebEvent) string {
	raw, ok := e.Extra["mask_rects"]
	if !ok {
		return e.Image
	}
	var rects [][]float64
	if json.Unmarshal(raw, &rects) != nil || len(rects) == 0 {
		return e.Image
	}
	comma := strings.IndexByte(e.Image, ',')
	if !strings.HasPrefix(e.Image, "data:image/") || comma < 0 {
		return blankFrame
	}
	data, err := base64.StdEncoding.DecodeString(e.Image[comma+1:])
	if err != nil {
		return blankFrame
	}
	src, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return blankFrame
	}
	b := src.Bounds()
	img := image.NewRGBA(b)
	draw.Draw(img, b, src, b.Min, draw.Src)
	sx, sy := 1.0, 1.0
	if e.Width > 0 && e.Height > 0 {
		sx, sy = float64(b.Dx())/e.Width, float64(b.Dy())/e.Height
	}
	for _, r := range rects {
		if len(r) != 4 {
			continue
		}
		rect := image.Rect(int(r[0]*sx), int(r[1]*sy), int((r[0]+r[2])*sx+0.999), int((r[1]+r[3])*sy+0.999)).Add(b.Min).Intersect(b)
		draw.Draw(img, rect, &image.Uniform{maskFill}, image.Point{}, draw.Src)
	}
	var out bytes.Buffer
	if err := jpeg.Encode(&out, img, &jpeg.Options{Quality: 70}); err != nil {
		return blankFrame
	}
	return "data:image/jpeg;base64," + base64.StdEncoding.EncodeToString(out.Bytes())
}

// blankFrame: a 1x1 grey PNG, stretched over the screen by the player.
var blankFrame = func() string {
	img := image.NewRGBA(image.Rect(0, 0, 1, 1))
	img.Set(0, 0, maskFill)
	var b bytes.Buffer
	png.Encode(&b, img)
	return "data:image/png;base64," + base64.StdEncoding.EncodeToString(b.Bytes())
}()
