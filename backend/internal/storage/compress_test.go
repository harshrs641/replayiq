package storage

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"io"
	"os"
	"strings"
	"testing"
)

func gz(t *testing.T, s string) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if _, err := zw.Write([]byte(s)); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func readAll(t *testing.T, r io.Reader) string {
	t.Helper()
	body, err := openBatch(r)
	if err != nil {
		t.Fatal(err)
	}
	b, err := io.ReadAll(body)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestOpenBatchGzip(t *testing.T) {
	const want = `{"session_id":"s1","events":[{"type":2}]}`
	if got := readAll(t, bytes.NewReader(gz(t, want))); got != want {
		t.Fatalf("got %q", got)
	}
}

func TestOpenBatchLegacyUncompressed(t *testing.T) {
	const want = `{"session_id":"s1","events":[]}`
	if got := readAll(t, strings.NewReader(want)); got != want {
		t.Fatalf("got %q", got)
	}
}

func TestOpenBatchTinyObject(t *testing.T) {
	// Shorter than the 2-byte magic peek: must not error.
	if got := readAll(t, strings.NewReader("{")); got != "{" {
		t.Fatalf("got %q", got)
	}
}

// REPLAYIQ_SAMPLE=<replay JSON from /api/v1/sessions/{id}/replay> reports the
// stored size before/after for a real session.
func TestCompressionRatioOnSample(t *testing.T) {
	path := os.Getenv("REPLAYIQ_SAMPLE")
	if path == "" {
		t.Skip("REPLAYIQ_SAMPLE not set")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var replay struct {
		Batches []json.RawMessage `json:"batches"`
	}
	if err := json.Unmarshal(raw, &replay); err != nil {
		t.Fatal(err)
	}
	var before, after int
	for _, b := range replay.Batches {
		before += len(b)
		z := gz(t, string(b))
		after += len(z)
		if got := readAll(t, bytes.NewReader(z)); got != string(b) {
			t.Fatal("round trip mismatch")
		}
	}
	t.Logf("%d batches: %d KB -> %d KB (%.1fx)", len(replay.Batches), before/1024, after/1024, float64(before)/float64(after))
}
