package storage

import (
	"bytes"
	"context"
	"io"
	"regexp"

	"github.com/minio/minio-go/v7"
)

// Assets (images, raster islands, fonts) referenced by Native DOM
// recordings, stored once per project under their sha256.

var assetHashRe = regexp.MustCompile(`^[0-9a-f]{64}$`)

// ValidAssetHash reports whether h is a lowercase hex sha256.
func ValidAssetHash(h string) bool { return assetHashRe.MatchString(h) }

func assetKey(projectID, hash string) string { return "assets/" + projectID + "/" + hash }

// HasAsset reports whether a project already has the asset.
func (m *MinIO) HasAsset(ctx context.Context, projectID, hash string) (bool, error) {
	_, err := m.client.StatObject(ctx, m.assetBucket, assetKey(projectID, hash), minio.StatObjectOptions{})
	if err == nil {
		return true, nil
	}
	if minio.ToErrorResponse(err).Code == "NoSuchKey" {
		return false, nil
	}
	return false, err
}

// PutAsset stores an asset (the caller has checked its hash).
func (m *MinIO) PutAsset(ctx context.Context, projectID, hash, contentType string, data []byte) error {
	_, err := m.client.PutObject(ctx, m.assetBucket, assetKey(projectID, hash), bytes.NewReader(data), int64(len(data)),
		minio.PutObjectOptions{ContentType: contentType})
	return err
}

// GetAsset opens an asset; the caller closes it.
func (m *MinIO) GetAsset(ctx context.Context, projectID, hash string) (io.ReadCloser, string, int64, error) {
	obj, err := m.client.GetObject(ctx, m.assetBucket, assetKey(projectID, hash), minio.GetObjectOptions{})
	if err != nil {
		return nil, "", 0, err
	}
	info, err := obj.Stat()
	if err != nil {
		obj.Close()
		return nil, "", 0, err
	}
	return obj, info.ContentType, info.Size, nil
}
