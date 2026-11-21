package api

import (
	"compress/gzip"
	"errors"
	"io"
	"net/http"
	"strings"
)

// errBodyTooLarge: the (decompressed) request body is over the limit.
var errBodyTooLarge = errors.New("request body too large")

// readIngestBody reads a recording API request body, gunzipping it when the
// SDK sent Content-Encoding: gzip (docs/sdk/recording-api-v1.md). limit
// applies to the decompressed size, so a small gzip can't expand without
// bound.
func readIngestBody(w http.ResponseWriter, req *http.Request, limit int64) ([]byte, error) {
	var r io.Reader = http.MaxBytesReader(w, req.Body, limit)
	if strings.EqualFold(strings.TrimSpace(req.Header.Get("Content-Encoding")), "gzip") {
		zr, err := gzip.NewReader(r)
		if err != nil {
			return nil, err
		}
		defer zr.Close()
		r = zr
	}
	body, err := io.ReadAll(io.LimitReader(r, limit+1))
	if err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			return nil, errBodyTooLarge
		}
		return nil, err
	}
	if int64(len(body)) > limit {
		return nil, errBodyTooLarge
	}
	return body, nil
}

// ingestKey returns the bearer token SDKs send (recording API v1). Until
// ingest keys exist it is the project id, used when the body has none.
func ingestKey(req *http.Request) string {
	h := req.Header.Get("Authorization")
	if len(h) > 7 && strings.EqualFold(h[:7], "bearer ") {
		return strings.TrimSpace(h[7:])
	}
	return ""
}

// writeBodyError answers a failed readIngestBody.
func writeBodyError(w http.ResponseWriter, err error) {
	if errors.Is(err, errBodyTooLarge) {
		writeError(w, http.StatusRequestEntityTooLarge, "body too large (5 MB max, decompressed)")
		return
	}
	writeError(w, http.StatusBadRequest, "invalid body")
}
