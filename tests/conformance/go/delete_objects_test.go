package conformance

import (
	"bytes"
	"context"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

func TestDeleteObjects_Batch(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "dos")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed CreateBucket: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	keys := []string{"a", "b", "c"}
	for _, k := range keys {
		if _, err := c.PutObject(context.Background(), &s3.PutObjectInput{
			Bucket: aws.String(bucket),
			Key:    aws.String(k),
			Body:   bytes.NewReader([]byte("v")),
		}); err != nil {
			t.Fatalf("seed Put %s: %v", k, err)
		}
	}

	ids := make([]types.ObjectIdentifier, 0, len(keys))
	for _, k := range keys {
		k := k
		ids = append(ids, types.ObjectIdentifier{Key: aws.String(k)})
	}
	out, err := c.DeleteObjects(context.Background(), &s3.DeleteObjectsInput{
		Bucket: aws.String(bucket),
		Delete: &types.Delete{Objects: ids},
	})
	if err != nil {
		t.Fatalf("DeleteObjects: %v", err)
	}
	if len(out.Deleted) != len(keys) {
		t.Fatalf("expected %d deleted entries, got %d", len(keys), len(out.Deleted))
	}

	// All keys should be gone.
	for _, k := range keys {
		_, err := c.HeadObject(context.Background(), &s3.HeadObjectInput{
			Bucket: aws.String(bucket),
			Key:    aws.String(k),
		})
		if err == nil {
			t.Errorf("%s still present after DeleteObjects", k)
		}
	}
}

// AWS includes missing keys in `Deleted` (no Error) — DeleteObjects is
// idempotent per-key. Nanostack mirrors this.
func TestDeleteObjects_MixedExistMissing(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "dom")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed CreateBucket: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("exists"),
		Body:   bytes.NewReader([]byte("v")),
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	out, err := c.DeleteObjects(context.Background(), &s3.DeleteObjectsInput{
		Bucket: aws.String(bucket),
		Delete: &types.Delete{Objects: []types.ObjectIdentifier{
			{Key: aws.String("exists")},
			{Key: aws.String("never-existed")},
		}},
	})
	if err != nil {
		t.Fatalf("DeleteObjects: %v", err)
	}
	if len(out.Deleted) != 2 {
		t.Errorf("both keys should be in Deleted; got %d entries", len(out.Deleted))
	}
	if len(out.Errors) != 0 {
		t.Errorf("expected no per-key errors, got %d", len(out.Errors))
	}
}
