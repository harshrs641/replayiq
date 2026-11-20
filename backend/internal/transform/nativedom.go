package transform

// Native DOM (docs/sdk/recording-api-v1.1-native-dom.md) → rrweb.
//
// A mobile SDK sends its UI as a tree of nodes (ui_snapshot) and changes to
// it (ui_mutation). Each node becomes an absolutely positioned HTML element
// with its styles, so the web player, keyframe index and seeking work as
// for a web page:
//
//	ui_snapshot → Meta + FullSnapshot (+ Scroll events for scrolled nodes)
//	ui_mutation → one Mutation event (+ Scroll events)
//
// Conversion is stateless: rrweb ids derive from the SDK's node ids, and an
// update carries the node's complete own fields.

import (
	"encoding/json"
	"fmt"
	"math"
	"strconv"
	"strings"

	"github.com/harshrs641/replayiq/internal/models"
)

const (
	srcScroll = 3

	pageDocument = 1
	pageDoctype  = 2
	pageHTML     = 3
	pageHead     = 4
	pageStyle    = 5
	pageBody     = 6
	// pageScreen holds the UI. It shares its id with the screenshot page's
	// image (nodeImage), so v1 `touch` events land on the screen in either
	// recording mode.
	pageScreen = nodeImage
)

// Element and text-child ids of a native node.
func elemID(n int) int { return 1000 + 4*n }
func textID(n int) int { return 1001 + 4*n }

func parentElem(p int) int {
	if p <= 0 {
		return pageScreen
	}
	return elemID(p)
}

type ndNode struct {
	ID    int       `json:"id"`
	K     string    `json:"k"`
	F     []float64 `json:"f"`
	S     *ndStyle  `json:"s"`
	Role  string    `json:"role"`
	Label string    `json:"label"`
	C     []ndNode  `json:"c"`
	Tx    *ndText   `json:"tx"`
	Img   *ndImage  `json:"img"`
	In    *ndInput  `json:"in"`
	So    []float64 `json:"so"`
	// Masked (raw recordings, v1.2): masked mode would hide this node; the
	// masked copy turns it into a mask block.
	Masked bool   `json:"masked"`
	Hint   string `json:"hint"`
}

type ndStyle struct {
	Bg   string    `json:"bg"`
	R    []float64 `json:"r"`
	Bw   float64   `json:"bw"`
	Bc   string    `json:"bc"`
	Sh   []any     `json:"sh"`
	O    *float64  `json:"o"`
	T    []float64 `json:"t"`
	Clip bool      `json:"clip"`
	Grad *ndGrad   `json:"grad"`
}

type ndGrad struct {
	Type  string  `json:"type"`
	Angle float64 `json:"angle"`
	Stops [][]any `json:"stops"`
}

type ndText struct {
	V     string   `json:"v"`
	Spans []ndText `json:"spans"`
	Font  string   `json:"font"`
	Size  float64  `json:"size"`
	W     int      `json:"w"`
	I     bool     `json:"i"`
	Col   string   `json:"col"`
	Al    string   `json:"al"`
	Lh    float64  `json:"lh"`
	Ml    int      `json:"ml"`
}

type ndImage struct {
	A   string `json:"a"`
	Fit string `json:"fit"`
}

type ndInput struct {
	Type  string `json:"type"`
	Ph    string `json:"ph"`
	Len   int    `json:"len"`
	Focus bool   `json:"focus"`
	// V: the field's value, sent only in raw recordings (never passwords).
	V string `json:"v"`
}

type ndFont struct {
	Family string `json:"family"`
	W      int    `json:"w"`
	A      string `json:"a"`
}

type ndAdd struct {
	P    int    `json:"p"`
	Next int    `json:"next"`
	N    ndNode `json:"n"`
}

type ndRemove struct {
	P  int `json:"p"`
	ID int `json:"id"`
}

// converter turns native nodes into rrweb nodes.
type converter struct {
	opt     Options
	scrolls []models.RRWebEvent // Scroll events to emit after the main one
	ts      int64
}

func (c *converter) text(s string) string {
	if c.opt.MaskText != nil {
		return c.opt.MaskText(s)
	}
	return s
}

func (c *converter) asset(hash string) string {
	if hash == "" || c.opt.AssetURL == nil {
		return ""
	}
	return c.opt.AssetURL(hash)
}

// convertSnapshot handles a ui_snapshot event.
func (c *converter) convertSnapshot(e models.RRWebEvent) ([]models.RRWebEvent, error) {
	var root ndNode
	if err := json.Unmarshal(e.Extra["root"], &root); err != nil {
		return nil, fmt.Errorf("ui_snapshot root: %w", err)
	}
	var fonts []ndFont
	if raw, ok := e.Extra["fonts"]; ok {
		json.Unmarshal(raw, &fonts)
	}
	var bg string
	if raw, ok := e.Extra["bg"]; ok {
		json.Unmarshal(raw, &bg)
	}
	c.ts = e.Timestamp

	css := strings.Builder{}
	css.WriteString("html,body{margin:0;padding:0;overflow:hidden;}*{box-sizing:border-box;}")
	for _, f := range fonts {
		if url := c.asset(f.A); url != "" && f.Family != "" {
			fmt.Fprintf(&css, "@font-face{font-family:%q;font-weight:%d;src:url(%q);}", f.Family, orInt(f.W, 400), url)
		}
	}
	screen := element(pageScreen, "div", map[string]any{
		"style": fmt.Sprintf("position:relative;overflow:hidden;width:%s;height:%s;", px(e.Width), px(e.Height)),
	}, c.node(root))
	page := map[string]any{
		"type": 0, "id": pageDocument,
		"childNodes": []any{
			map[string]any{"type": 1, "id": pageDoctype, "name": "html", "publicId": "", "systemId": ""},
			element(pageHTML, "html", map[string]any{},
				element(pageHead, "head", map[string]any{},
					element(pageStyle, "style", map[string]any{"_cssText": css.String()})),
				element(pageBody, "body", map[string]any{"style": "background:" + color(orStr(bg, "#FFFFFFFF")) + ";"}, screen)),
		},
	}
	out := []models.RRWebEvent{
		{Type: rrMeta, Timestamp: e.Timestamp, Data: map[string]any{"width": e.Width, "height": e.Height}},
		{Type: rrFullSnapshot, Timestamp: e.Timestamp, Data: map[string]any{
			"node": page, "initialOffset": map[string]any{"top": 0, "left": 0},
		}},
	}
	return append(out, c.scrolls...), nil
}

// convertMutation handles a ui_mutation event.
func (c *converter) convertMutation(e models.RRWebEvent) ([]models.RRWebEvent, error) {
	var adds []ndAdd
	var removes []ndRemove
	var updates []ndNode
	for key, dst := range map[string]any{"adds": &adds, "removes": &removes, "updates": &updates} {
		if raw, ok := e.Extra[key]; ok {
			if err := json.Unmarshal(raw, dst); err != nil {
				return nil, fmt.Errorf("ui_mutation %s: %w", key, err)
			}
		}
	}
	c.ts = e.Timestamp
	texts, attrs := []any{}, []any{}
	rmList, addList := []any{}, []any{}
	for _, r := range removes {
		rmList = append(rmList, map[string]any{"parentId": parentElem(r.P), "id": elemID(r.ID)})
	}
	for _, a := range adds {
		var next any
		if a.Next > 0 {
			next = elemID(a.Next)
		}
		addList = appendFlat(addList, parentElem(a.P), next, c.node(a.N))
	}
	for _, u := range updates {
		c.hide(&u)
		at := map[string]any{"style": c.css(u)}
		if u.K == "image" || u.K == "island" {
			at["src"] = c.imageSrc(u)
		}
		attrs = append(attrs, map[string]any{"id": elemID(u.ID), "attributes": at})
		if v, ok := c.textValue(u); ok {
			texts = append(texts, map[string]any{"id": textID(u.ID), "value": v})
		}
		c.addScroll(u)
	}
	out := []models.RRWebEvent{{Type: rrIncremental, Timestamp: e.Timestamp, Data: map[string]any{
		"source": srcMutation, "texts": texts, "attributes": attrs, "removes": rmList, "adds": addList,
	}}}
	return append(out, c.scrolls...), nil
}

// appendFlat adds a subtree as rrweb expects it: rrweb builds each added
// node without its children, so every descendant is its own entry, parents
// first, appended in order.
func appendFlat(adds []any, parentID int, next any, node map[string]any) []any {
	kids, _ := node["childNodes"].([]any)
	flat := make(map[string]any, len(node))
	for k, v := range node {
		flat[k] = v
	}
	flat["childNodes"] = []any{}
	adds = append(adds, map[string]any{"parentId": parentID, "nextId": next, "node": flat})
	id, _ := node["id"].(int)
	for _, k := range kids {
		child, _ := k.(map[string]any)
		if child == nil {
			continue
		}
		if _, isElem := child["childNodes"]; isElem {
			adds = appendFlat(adds, id, nil, child)
		} else {
			adds = append(adds, map[string]any{"parentId": id, "nextId": nil, "node": child})
		}
	}
	return adds
}

// blankImage is a transparent pixel: the src of an image whose asset isn't
// known yet.
const blankImage = "data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="

func (c *converter) imageSrc(n ndNode) string {
	if n.Img != nil {
		if url := c.asset(n.Img.A); url != "" {
			return url
		}
	}
	return blankImage
}

func (c *converter) addScroll(n ndNode) {
	if n.K == "scroll" && len(n.So) == 2 {
		c.scrolls = append(c.scrolls, models.RRWebEvent{Type: rrIncremental, Timestamp: c.ts, Data: map[string]any{
			"source": srcScroll, "id": elemID(n.ID), "x": n.So[0], "y": n.So[1],
		}})
	}
}

// textValue is what a text or input node displays.
func (c *converter) textValue(n ndNode) (string, bool) {
	switch n.K {
	case "text":
		if n.Tx == nil {
			return "", true
		}
		return c.text(joinText(n.Tx)), true
	case "input":
		if n.In == nil {
			return "", true
		}
		if n.In.V != "" && !c.opt.MaskNodes && n.In.Type != "password" {
			return c.text(n.In.V), true
		}
		if n.In.Len > 0 {
			return strings.Repeat("•", min(n.In.Len, 40)), true
		}
		return c.text(n.In.Ph), true
	}
	return "", false
}

func joinText(t *ndText) string {
	if len(t.Spans) == 0 {
		return t.V
	}
	var b strings.Builder
	for _, s := range t.Spans {
		b.WriteString(s.V)
	}
	return b.String()
}

// hide turns a node that masked mode would hide into a mask block (for the
// masked copy of a raw recording).
func (c *converter) hide(n *ndNode) {
	if c.opt.MaskNodes && n.Masked {
		n.K, n.C, n.Tx, n.Img, n.In = "mask", nil, nil, nil, nil
	}
}

// node converts a native node and its subtree.
func (c *converter) node(n ndNode) map[string]any {
	c.hide(&n)
	attrs := map[string]any{"style": c.css(n)}
	if n.Role != "" {
		attrs["data-role"] = n.Role
	}
	if n.Label != "" {
		attrs["aria-label"] = c.text(n.Label)
	}
	c.addScroll(n)
	switch n.K {
	case "image", "island":
		// Always an <img>: an image that finishes uploading later arrives as
		// an update, which can change src but not the element type.
		attrs["src"] = c.imageSrc(n)
		if n.Hint != "" {
			attrs["title"] = n.Hint
		}
		return element(elemID(n.ID), "img", attrs)
	case "mask", "web":
		return element(elemID(n.ID), "div", attrs)
	case "text", "input":
		v, _ := c.textValue(n)
		return element(elemID(n.ID), "div", attrs, map[string]any{"type": 3, "id": textID(n.ID), "textContent": v})
	}
	kids := make([]any, 0, len(n.C))
	for _, child := range n.C {
		kids = append(kids, c.node(child))
	}
	return element(elemID(n.ID), "div", attrs, kids...)
}

// css is the inline style of a node.
func (c *converter) css(n ndNode) string {
	var b strings.Builder
	b.WriteString("position:absolute;")
	if len(n.F) == 4 {
		fmt.Fprintf(&b, "left:%s;top:%s;width:%s;height:%s;", px(n.F[0]), px(n.F[1]), px(n.F[2]), px(n.F[3]))
	}
	if s := n.S; s != nil {
		if s.Bg != "" {
			b.WriteString("background-color:" + color(s.Bg) + ";")
		}
		if g := s.Grad; g != nil && len(g.Stops) > 0 {
			stops := make([]string, 0, len(g.Stops))
			for _, st := range g.Stops {
				if len(st) == 2 {
					col, _ := st[0].(string)
					pos, _ := st[1].(float64)
					stops = append(stops, fmt.Sprintf("%s %s%%", color(col), num(pos*100)))
				}
			}
			if g.Type == "radial" {
				b.WriteString("background-image:radial-gradient(circle," + strings.Join(stops, ",") + ");")
			} else {
				b.WriteString("background-image:linear-gradient(" + num(g.Angle) + "deg," + strings.Join(stops, ",") + ");")
			}
		}
		if len(s.R) == 4 {
			fmt.Fprintf(&b, "border-radius:%s %s %s %s;", px(s.R[0]), px(s.R[1]), px(s.R[2]), px(s.R[3]))
		}
		if s.Bw > 0 {
			fmt.Fprintf(&b, "border:%s solid %s;", px(s.Bw), color(orStr(s.Bc, "#FF000000")))
		}
		if len(s.Sh) == 5 {
			dx, _ := s.Sh[0].(float64)
			dy, _ := s.Sh[1].(float64)
			blur, _ := s.Sh[2].(float64)
			spread, _ := s.Sh[3].(float64)
			col, _ := s.Sh[4].(string)
			fmt.Fprintf(&b, "box-shadow:%s %s %s %s %s;", px(dx), px(dy), px(blur), px(spread), color(col))
		}
		if s.O != nil && *s.O < 1 {
			b.WriteString("opacity:" + num(*s.O) + ";")
		}
		if len(s.T) == 6 && !isIdentity(s.T) {
			fmt.Fprintf(&b, "transform:matrix(%s,%s,%s,%s,%s,%s);", num(s.T[0]), num(s.T[1]), num(s.T[2]), num(s.T[3]), num(s.T[4]), num(s.T[5]))
		}
		if s.Clip {
			b.WriteString("overflow:hidden;")
		}
	}
	switch n.K {
	case "scroll":
		b.WriteString("overflow:hidden;")
	case "image", "island":
		if n.K == "island" && (n.Img == nil || n.Img.A == "") {
			// No pixels (yet, or ever: e.g. a platform view).
			b.WriteString("background-color:#e5e7eb;")
		}
		if n.Img != nil {
			fit := n.Img.Fit
			if fit == "" {
				fit = "fill"
			}
			b.WriteString("object-fit:" + fit + ";")
		}
	case "mask":
		b.WriteString("background:repeating-linear-gradient(45deg,#9ca3af,#9ca3af 6px,#d1d5db 6px,#d1d5db 12px);")
	case "web":
		b.WriteString("background-color:#f3f4f6;")
	case "text":
		if t := n.Tx; t != nil {
			style := t
			if len(t.Spans) > 0 {
				style = &t.Spans[0]
				if style.Font == "" {
					style.Font = t.Font
				}
			}
			textCSS(&b, style, t.Ml, frameHeight(n))
		}
	case "input":
		b.WriteString("display:flex;align-items:center;padding:0 8px;white-space:nowrap;overflow:hidden;")
		b.WriteString("font:15px " + fontStack("") + ";")
		if n.In != nil {
			if n.In.Len == 0 && (n.In.V == "" || c.opt.MaskNodes) {
				b.WriteString("color:#9ca3af;")
			}
			if n.In.Focus {
				b.WriteString("outline:2px solid #3b82f6;")
			}
		}
	}
	return b.String()
}

func frameHeight(n ndNode) float64 {
	if len(n.F) == 4 {
		return n.F[3]
	}
	return 0
}

// textCSS styles a text node. Text is not clipped to its frame: the viewer
// may lack the app's exact font (e.g. Apple's system font off a Mac), and
// a slightly wider substitute must not cut words off. A frame one line
// tall keeps its text on one line.
func textCSS(b *strings.Builder, t *ndText, maxLines int, height float64) {
	line := t.Lh
	if line <= 0 {
		line = t.Size * 1.3
	}
	if maxLines == 1 || (line > 0 && height > 0 && height < line*1.6) {
		b.WriteString("white-space:pre;")
	} else {
		b.WriteString("white-space:pre-wrap;")
	}
	b.WriteString("font-family:" + fontStack(t.Font) + ";")
	if t.Size > 0 {
		b.WriteString("font-size:" + px(t.Size) + ";")
	}
	if t.W > 0 {
		b.WriteString("font-weight:" + strconv.Itoa(t.W) + ";")
	}
	if t.I {
		b.WriteString("font-style:italic;")
	}
	if t.Col != "" {
		b.WriteString("color:" + color(t.Col) + ";")
	}
	if t.Al != "" {
		b.WriteString("text-align:" + t.Al + ";")
	}
	if t.Lh > 0 {
		b.WriteString("line-height:" + px(t.Lh) + ";")
	}
	if maxLines > 1 {
		fmt.Fprintf(b, "overflow:hidden;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:%d;", maxLines)
	}
}

// fontStack names the app's font first, then platform system fonts: viewers
// on a Mac get Apple's system font, others Roboto or a close substitute.
func fontStack(family string) string {
	system := `-apple-system,BlinkMacSystemFont,"SF Pro Text",Roboto,"Helvetica Neue",Arial,sans-serif`
	f := strings.TrimSpace(family)
	if f == "" || strings.HasPrefix(f, ".") || strings.EqualFold(f, "system") || strings.Contains(f, "SF") {
		return system
	}
	return strconv.Quote(f) + "," + system
}

// color converts #AARRGGBB (or #RRGGBB) to CSS.
func color(c string) string {
	h := strings.TrimPrefix(strings.TrimSpace(c), "#")
	switch len(h) {
	case 6:
		h = "FF" + h
	case 8:
	default:
		return "transparent"
	}
	v, err := strconv.ParseUint(h, 16, 32)
	if err != nil {
		return "transparent"
	}
	a, r, g, bl := v>>24&0xff, v>>16&0xff, v>>8&0xff, v&0xff
	if a == 0xff {
		return fmt.Sprintf("rgb(%d,%d,%d)", r, g, bl)
	}
	return fmt.Sprintf("rgba(%d,%d,%d,%s)", r, g, bl, num(float64(a)/255))
}

func px(v float64) string { return num(v) + "px" }

func num(v float64) string {
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return "0"
	}
	return strconv.FormatFloat(math.Round(v*100)/100, 'f', -1, 64)
}

func isIdentity(t []float64) bool {
	return t[0] == 1 && t[1] == 0 && t[2] == 0 && t[3] == 1 && t[4] == 0 && t[5] == 0
}

func element(id int, tag string, attrs map[string]any, children ...any) map[string]any {
	if children == nil {
		children = []any{}
	}
	return map[string]any{"type": 2, "id": id, "tagName": tag, "attributes": attrs, "childNodes": children}
}

func orStr(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

func orInt(v, def int) int {
	if v == 0 {
		return def
	}
	return v
}
