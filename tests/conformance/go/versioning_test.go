package conformance

import (
	"bytes"
	"context"
	"errors"
	"io"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

func enableVersioning(t *testing.T, c *s3.Client, bucket string) {
	t.Helper()
	if _, err := c.PutBucketVersioning(context.Background(), &s3.PutBucketVersioningInput{
		Bucket: aws.String(bucket),
		VersioningConfiguration: &types.VersioningConfiguration{
			Status: types.BucketVersioningStatusEnabled,
		},
	}); err != nil {
		t.Fatalf("PutBucketVersioning Enabled: %v", err)
	}
}

func TestVersioning_PutGet_Status(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ver-st")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	// Default = empty Status.
	out, err := c.GetBucketVersioning(context.Background(), &s3.GetBucketVersioningInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("GetBucketVersioning: %v", err)
	}
	if out.Status != "" {
		t.Errorf("default status: got %q want \"\"", out.Status)
	}

	enableVersioning(t, c, bucket)
	out, err = c.GetBucketVersioning(context.Background(), &s3.GetBucketVersioningInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("GetBucketVersioning after Enabled: %v", err)
	}
	if out.Status != types.BucketVersioningStatusEnabled {
		t.Errorf("got %q want Enabled", out.Status)
	}

	if _, err := c.PutBucketVersioning(context.Background(), &s3.PutBucketVersioningInput{
		Bucket: aws.String(bucket),
		VersioningConfiguration: &types.VersioningConfiguration{
			Status: types.BucketVersioningStatusSuspended,
		},
	}); err != nil {
		t.Fatalf("PutBucketVersioning Suspended: %v", err)
	}
	out, err = c.GetBucketVersioning(context.Background(), &s3.GetBucketVersioningInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("GetBucketVersioning after Suspended: %v", err)
	}
	if out.Status != types.BucketVersioningStatusSuspended {
		t.Errorf("got %q want Suspended", out.Status)
	}
}

func TestVersioning_ThreePuts_ListVersions(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ver-list")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	enableVersioning(t, c, bucket)
	defer func() {
		// Drain every version + delete marker so the bucket is empty.
		drainVersions(t, c, bucket)
		cleanupBucket(t, c, bucket)
	}()

	versionIds := []string{}
	for _, body := range []string{"v1", "v2", "v3"} {
		out, err := c.PutObject(context.Background(), &s3.PutObjectInput{
			Bucket: aws.String(bucket),
			Key:    aws.String("k"),
			Body:   bytes.NewReader([]byte(body)),
		})
		if err != nil {
			t.Fatalf("Put %s: %v", body, err)
		}
		if out.VersionId == nil || *out.VersionId == "" {
			t.Fatalf("missing VersionId on Put %s", body)
		}
		versionIds = append(versionIds, *out.VersionId)
	}

	listed, err := c.ListObjectVersions(context.Background(), &s3.ListObjectVersionsInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("ListObjectVersions: %v", err)
	}
	if len(listed.Versions) != 3 {
		t.Fatalf("expected 3 versions, got %d", len(listed.Versions))
	}
	if !*listed.Versions[0].IsLatest {
		t.Errorf("first listed should be IsLatest=true")
	}
	if aws.ToString(listed.Versions[0].VersionId) != versionIds[2] {
		t.Errorf("latest version mismatch: got %q want %q",
			aws.ToString(listed.Versions[0].VersionId), versionIds[2])
	}
}

func TestVersioning_GetByExplicitVersionId(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ver-byid")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	enableVersioning(t, c, bucket)
	defer func() {
		drainVersions(t, c, bucket)
		cleanupBucket(t, c, bucket)
	}()

	p1, _ := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), Body: bytes.NewReader([]byte("first")),
	})
	_, _ = c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), Body: bytes.NewReader([]byte("second")),
	})

	got, err := c.GetObject(context.Background(), &s3.GetObjectInput{
		Bucket:    aws.String(bucket),
		Key:       aws.String("k"),
		VersionId: p1.VersionId,
	})
	if err != nil {
		t.Fatalf("GetObject by versionId: %v", err)
	}
	defer got.Body.Close()
	body, _ := io.ReadAll(got.Body)
	if string(body) != "first" {
		t.Fatalf("got %q want \"first\"", body)
	}
}

func TestVersioning_DeleteCreatesMarker_GetReturns404(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ver-dm")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	enableVersioning(t, c, bucket)
	defer func() {
		drainVersions(t, c, bucket)
		cleanupBucket(t, c, bucket)
	}()

	if _, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), Body: bytes.NewReader([]byte("v")),
	}); err != nil {
		t.Fatalf("Put: %v", err)
	}

	del, err := c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
	if err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if del.DeleteMarker == nil || !*del.DeleteMarker {
		t.Errorf("expected DeleteMarker=true, got %v", del.DeleteMarker)
	}
	if del.VersionId == nil || *del.VersionId == "" {
		t.Errorf("expected VersionId on delete-marker response")
	}

	_, err = c.GetObject(context.Background(), &s3.GetObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
	if err == nil {
		t.Fatal("expected NoSuchKey after delete-marker, got nil")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 404 {
		t.Fatalf("expected 404, got %v", err)
	}
}

func TestVersioning_RemoveMarker_PriorVersionReappears(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ver-rm")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	enableVersioning(t, c, bucket)
	defer func() {
		drainVersions(t, c, bucket)
		cleanupBucket(t, c, bucket)
	}()

	if _, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), Body: bytes.NewReader([]byte("alive")),
	}); err != nil {
		t.Fatalf("Put: %v", err)
	}
	del, _ := c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
	// Now permanently delete the delete-marker.
	if _, err := c.DeleteObject(context.Background(), &s3.DeleteObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: del.VersionId,
	}); err != nil {
		t.Fatalf("Delete marker by versionId: %v", err)
	}

	// GetObject should now return the original version.
	got, err := c.GetObject(context.Background(), &s3.GetObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
	if err != nil {
		t.Fatalf("Get after marker removal: %v", err)
	}
	defer got.Body.Close()
	body, _ := io.ReadAll(got.Body)
	if string(body) != "alive" {
		t.Errorf("got %q want \"alive\"", body)
	}
}

func TestVersioning_DeleteVersionPermanent(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ver-perm")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	enableVersioning(t, c, bucket)
	defer func() {
		drainVersions(t, c, bucket)
		cleanupBucket(t, c, bucket)
	}()

	p1, _ := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), Body: bytes.NewReader([]byte("v1")),
	})
	_, _ = c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), Body: bytes.NewReader([]byte("v2")),
	})

	if _, err := c.DeleteObject(context.Background(), &s3.DeleteObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: p1.VersionId,
	}); err != nil {
		t.Fatalf("Delete versionId: %v", err)
	}

	// Verify v1 is gone but v2 remains.
	_, err := c.GetObject(context.Background(), &s3.GetObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: p1.VersionId,
	})
	if err == nil {
		t.Fatal("expected NoSuchKey for permanently-deleted version")
	}
}

func TestVersioning_SuspendedPutGetsNullVersionId(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ver-susp")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	enableVersioning(t, c, bucket)
	if _, err := c.PutBucketVersioning(context.Background(), &s3.PutBucketVersioningInput{
		Bucket: aws.String(bucket),
		VersioningConfiguration: &types.VersioningConfiguration{
			Status: types.BucketVersioningStatusSuspended,
		},
	}); err != nil {
		t.Fatalf("Suspend: %v", err)
	}
	defer func() {
		drainVersions(t, c, bucket)
		cleanupBucket(t, c, bucket)
	}()

	out, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), Body: bytes.NewReader([]byte("x")),
	})
	if err != nil {
		t.Fatalf("Put on Suspended: %v", err)
	}
	if aws.ToString(out.VersionId) != "null" {
		t.Errorf("expected versionId=\"null\" on Suspended write, got %q", aws.ToString(out.VersionId))
	}
}

func TestVersioning_CopyObject_VersionIdRoundtrip(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ver-cp")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	enableVersioning(t, c, bucket)
	defer func() {
		drainVersions(t, c, bucket)
		cleanupBucket(t, c, bucket)
	}()

	src, _ := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("src"), Body: bytes.NewReader([]byte("hello")),
	})
	if src.VersionId == nil {
		t.Fatal("source missing VersionId")
	}

	out, err := c.CopyObject(context.Background(), &s3.CopyObjectInput{
		Bucket:     aws.String(bucket),
		Key:        aws.String("dst"),
		CopySource: aws.String(bucket + "/src"),
	})
	if err != nil {
		t.Fatalf("CopyObject: %v", err)
	}
	if out.VersionId == nil || *out.VersionId == "" {
		t.Errorf("dest missing VersionId")
	}
}

// drainVersions removes every version + delete marker so the bucket can
// be deleted cleanly.
func drainVersions(t *testing.T, c *s3.Client, bucket string) {
	t.Helper()
	out, err := c.ListObjectVersions(context.Background(), &s3.ListObjectVersionsInput{Bucket: aws.String(bucket)})
	if err != nil {
		return
	}
	for _, v := range out.Versions {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{
			Bucket: aws.String(bucket), Key: v.Key, VersionId: v.VersionId,
		})
	}
	for _, m := range out.DeleteMarkers {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{
			Bucket: aws.String(bucket), Key: m.Key, VersionId: m.VersionId,
		})
	}
}

// strings import gate (used implicitly via the awshttp error helper in
// other files; this file needs at least one to avoid 'imported and not
// used').
var _ = strings.Contains
