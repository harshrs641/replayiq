package api

import (
	"compress/gzip"
	"net/http"
	"strconv"
	"strings"
)

// gzipWriter compresses a handler's response body. Replay responses are
// large JSON (rrweb DOM snapshots compress ~5-10x); the gateway proxies the
// encoded body through untouched.
type gzipWriter struct {
	http.ResponseWriter
	zw *gzip.Writer
}

func (g *gzipWriter) Write(b []byte) (int, error) { return g.zw.Write(b) }

// Flush sends what is compressed so far (streamed responses).
func (g *gzipWriter) Flush() {
	g.zw.Flush()
	http.NewResponseController(g.ResponseWriter).Flush()
}

func (g *gzipWriter) Unwrap() http.ResponseWriter { return g.ResponseWriter }

func (g *gzipWriter) WriteHeader(code int) {
	g.Header().Del("Content-Length")
	g.ResponseWriter.WriteHeader(code)
}

// withGzip returns a writer that compresses when the client accepts gzip,
// and a func the handler must call (defer) to flush the stream.
func withGzip(w http.ResponseWriter, req *http.Request) (http.ResponseWriter, func()) {
	w.Header().Add("Vary", "Accept-Encoding")
	if !acceptsGzip(req.Header.Get("Accept-Encoding")) {
		return w, func() {}
	}
	w.Header().Set("Content-Encoding", "gzip")
	zw, _ := gzip.NewWriterLevel(w, gzip.DefaultCompression)
	return &gzipWriter{ResponseWriter: w, zw: zw}, func() { zw.Close() }
}

// acceptsGzip reports whether an Accept-Encoding header allows gzip
// ("gzip" or "*", unless given q=0).
func acceptsGzip(header string) bool {
	for _, part := range strings.Split(header, ",") {
		enc, params, _ := strings.Cut(strings.TrimSpace(part), ";")
		enc = strings.TrimSpace(enc)
		if !strings.EqualFold(enc, "gzip") && enc != "*" {
			continue
		}
		for _, p := range strings.Split(params, ";") {
			k, v, ok := strings.Cut(strings.TrimSpace(p), "=")
			if ok && strings.EqualFold(k, "q") {
				if q, err := strconv.ParseFloat(strings.TrimSpace(v), 64); err == nil && q == 0 {
					return false
				}
			}
		}
		return true
	}
	return false
}
