package api

// Assets for Native DOM recordings (docs/sdk/recording-api-v1.1-native-dom.md §3):
//
//	POST /api/v1/assets              upload (ingest key; X-Asset-Hash = sha256 of the body)
//	HEAD /api/v1/assets/{hash}       does the key's project have it? 200 / 404
//	GET  /api/v1/assets/{project}/{hash}  serve it to the replay player

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"strconv"
	"strings"

	"github.com/harshrs641/replayiq/internal/storage"
)

const maxAssetBytes = 2 << 20

var assetTypes = map[string]bool{
	"image/webp": true, "image/jpeg": true, "image/png": true, "image/gif": true,
	"font/ttf": true, "font/otf": true, "font/woff": true, "font/woff2": true,
}

func (r *router) uploadAsset(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	project := ingestKey(req)
	if project == "" {
		writeError(w, http.StatusUnauthorized, "missing ingest key")
		return
	}
	hash := strings.ToLower(strings.TrimSpace(req.Header.Get("X-Asset-Hash")))
	if !storage.ValidAssetHash(hash) {
		writeError(w, http.StatusBadRequest, "X-Asset-Hash must be the body's sha256 in hex")
		return
	}
	ctype, _, _ := mime.ParseMediaType(req.Header.Get("Content-Type"))
	if !assetTypes[ctype] {
		writeError(w, http.StatusBadRequest, "unsupported asset type")
		return
	}
	if ok, err := r.cfg.MinIO.HasAsset(req.Context(), project, hash); err == nil && ok {
		io.Copy(io.Discard, io.LimitReader(req.Body, maxAssetBytes))
		writeJSON(w, http.StatusOK, map[string]string{"status": "exists"})
		return
	}
	body, err := readIngestBody(w, req, maxAssetBytes)
	if err != nil {
		writeBodyError(w, err)
		return
	}
	sum := sha256.Sum256(body)
	if hex.EncodeToString(sum[:]) != hash {
		writeError(w, http.StatusBadRequest, "X-Asset-Hash does not match the body")
		return
	}
	if err := r.cfg.MinIO.PutAsset(req.Context(), project, hash, ctype, body); err != nil {
		slog.Error("store asset failed", "error", err)
		writeError(w, http.StatusServiceUnavailable, "try again")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"status": "stored"})
}

// assetByPath serves HEAD /api/v1/assets/{hash} and GET /api/v1/assets/{project}/{hash}.
func (r *router) assetByPath(w http.ResponseWriter, req *http.Request) {
	parts := strings.Split(strings.Trim(strings.TrimPrefix(req.URL.Path, "/api/v1/assets/"), "/"), "/")
	switch {
	case req.Method == http.MethodHead && len(parts) == 1:
		project := ingestKey(req)
		if project == "" || !storage.ValidAssetHash(parts[0]) {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		ok, err := r.cfg.MinIO.HasAsset(req.Context(), project, parts[0])
		if err != nil {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.WriteHeader(http.StatusOK)
	case (req.Method == http.MethodGet || req.Method == http.MethodHead) && len(parts) == 2:
		if parts[0] == "" || !storage.ValidAssetHash(parts[1]) {
			writeError(w, http.StatusNotFound, "not found")
			return
		}
		obj, ctype, size, err := r.cfg.MinIO.GetAsset(req.Context(), parts[0], parts[1])
		if err != nil {
			writeError(w, http.StatusNotFound, "not found")
			return
		}
		defer obj.Close()
		w.Header().Set("Content-Type", ctype)
		w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
		// Content-addressed: never changes.
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		if req.Method == http.MethodGet {
			io.Copy(w, obj)
		}
	default:
		writeError(w, http.StatusNotFound, "not found")
	}
}
