package api

import (
	"bytes"
	"compress/gzip"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestReadIngestBody(t *testing.T) {
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	zw.Write([]byte(`{"session_id":"s"}`))
	zw.Close()
	req := httptest.NewRequest("POST", "/api/v1/events", bytes.NewReader(gz.Bytes()))
	req.Header.Set("Content-Encoding", "gzip")
	body, err := readIngestBody(httptest.NewRecorder(), req, 1000)
	if err != nil || string(body) != `{"session_id":"s"}` {
		t.Fatalf("%q %v", body, err)
	}

	// The limit is on the decompressed size.
	gz.Reset()
	zw = gzip.NewWriter(&gz)
	zw.Write(bytes.Repeat([]byte("a"), 5000))
	zw.Close()
	req = httptest.NewRequest("POST", "/x", bytes.NewReader(gz.Bytes()))
	req.Header.Set("Content-Encoding", "gzip")
	if _, err := readIngestBody(httptest.NewRecorder(), req, 1000); !errors.Is(err, errBodyTooLarge) {
		t.Fatalf("want too large, got %v", err)
	}
	req = httptest.NewRequest("POST", "/x", strings.NewReader(strings.Repeat("a", 2000)))
	if _, err := readIngestBody(httptest.NewRecorder(), req, 1000); !errors.Is(err, errBodyTooLarge) {
		t.Fatalf("plain body over the limit: %v", err)
	}
}

func TestIngestKey(t *testing.T) {
	req := httptest.NewRequest("POST", "/x", nil)
	if ingestKey(req) != "" {
		t.Fatal("no header: no key")
	}
	req.Header.Set("Authorization", "Bearer  acme-web ")
	if ingestKey(req) != "acme-web" {
		t.Fatalf("%q", ingestKey(req))
	}
	req.Header.Set("Authorization", "Basic abc")
	if ingestKey(req) != "" {
		t.Fatal("basic auth is not an ingest key")
	}
}
