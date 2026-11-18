package api

import (
	"compress/gzip"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAcceptsGzip(t *testing.T) {
	for h, want := range map[string]bool{
		"":                          false,
		"gzip":                      true,
		"gzip, deflate, br, zstd":   true,
		"br;q=1.0, GZIP;q=0.5":      true,
		"gzip;q=0":                  false,
		"gzip; q=0.0, deflate":      false,
		"*":                         true,
		"deflate, br":               false,
		"x-gzip-something, deflate": false,
	} {
		if got := acceptsGzip(h); got != want {
			t.Errorf("%q: got %v want %v", h, got, want)
		}
	}
}

func TestWithGzipCompressesAndRoundTrips(t *testing.T) {
	body := strings.Repeat(`{"type":3,"data":{"source":0,"adds":[]}},`, 2000)
	for _, enc := range []string{"gzip", ""} {
		req := httptest.NewRequest("GET", "/", nil)
		req.Header.Set("Accept-Encoding", enc)
		rec := httptest.NewRecorder()
		w, done := withGzip(rec, req)
		w.Header().Set("Content-Length", "123") // must be dropped when compressing
		w.WriteHeader(http.StatusOK)
		io.WriteString(w, body)
		done()

		res := rec.Result()
		if res.Header.Get("Vary") != "Accept-Encoding" {
			t.Fatalf("Vary missing for %q", enc)
		}
		if enc == "" {
			if res.Header.Get("Content-Encoding") != "" || rec.Body.String() != body {
				t.Fatal("must not compress without Accept-Encoding")
			}
			continue
		}
		if res.Header.Get("Content-Encoding") != "gzip" || res.Header.Get("Content-Length") != "" {
			t.Fatalf("headers %v", res.Header)
		}
		if rec.Body.Len()*10 > len(body) {
			t.Fatalf("expected >10x on repetitive JSON, got %d -> %d", len(body), rec.Body.Len())
		}
		zr, err := gzip.NewReader(rec.Body)
		if err != nil {
			t.Fatal(err)
		}
		got, _ := io.ReadAll(zr)
		if string(got) != body {
			t.Fatal("round trip mismatch")
		}
	}
}

func TestReplaySourceMasked(t *testing.T) {
	if !(replaySource{DeviceMasked: true}).Masked() || !(replaySource{MaskedBucket: true}).Masked() || (replaySource{}).Masked() {
		t.Fatal("Masked() must be true for device-masked or masked-bucket sources only")
	}
	if m := buildManifest("s", replaySource{DeviceMasked: true}, nil); !m.Masked || !m.DeviceMasked {
		t.Fatalf("device-masked manifest: %+v", m)
	}
}
