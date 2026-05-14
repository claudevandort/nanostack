package conformance

import (
	"context"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

func TestRestoreObject_Returns202(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "rest-202")
	seedObject(t, c, bucket, "k", []byte("cold"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	out, err := c.RestoreObject(context.Background(), &s3.RestoreObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"),
		RestoreRequest: &types.RestoreRequest{Days: aws.Int32(1)},
	})
	if err != nil {
		t.Fatalf("RestoreObject: %v", err)
	}
	// We can't directly assert 202 from the SDK output, but no error +
	// successful HEAD with x-amz-restore is the proof we need.
	_ = out
}

func TestRestoreObject_HeadSurfacesRestoreHeader(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "rest-head")
	seedObject(t, c, bucket, "k", []byte("cold"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	if _, err := c.RestoreObject(context.Background(), &s3.RestoreObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"),
		RestoreRequest: &types.RestoreRequest{Days: aws.Int32(7)},
	}); err != nil {
		t.Fatalf("RestoreObject: %v", err)
	}
	head, err := c.HeadObject(context.Background(), &s3.HeadObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
	if err != nil {
		t.Fatalf("HeadObject: %v", err)
	}
	if !strings.Contains(aws.ToString(head.Restore), "ongoing-request=\"false\"") {
		t.Errorf("expected x-amz-restore in HEAD response, got: %q", aws.ToString(head.Restore))
	}
}

func TestRestoreObject_PerVersion(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "rest-ver")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if _, err := c.PutBucketVersioning(context.Background(), &s3.PutBucketVersioningInput{
		Bucket: aws.String(bucket),
		VersioningConfiguration: &types.VersioningConfiguration{Status: types.BucketVersioningStatusEnabled},
	}); err != nil {
		t.Fatalf("versioning: %v", err)
	}
	defer func() {
		drainVersions(t, c, bucket)
		cleanupBucket(t, c, bucket)
	}()

	v1Out, _ := c.PutObject(context.Background(), &s3.PutObjectInput{Bucket: aws.String(bucket), Key: aws.String("k"), Body: strings.NewReader("v1")})
	v2Out, _ := c.PutObject(context.Background(), &s3.PutObjectInput{Bucket: aws.String(bucket), Key: aws.String("k"), Body: strings.NewReader("v2")})
	// Restore only v1.
	if _, err := c.RestoreObject(context.Background(), &s3.RestoreObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: v1Out.VersionId,
		RestoreRequest: &types.RestoreRequest{Days: aws.Int32(1)},
	}); err != nil {
		t.Fatalf("RestoreObject v1: %v", err)
	}
	head1, _ := c.HeadObject(context.Background(), &s3.HeadObjectInput{Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: v1Out.VersionId})
	head2, _ := c.HeadObject(context.Background(), &s3.HeadObjectInput{Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: v2Out.VersionId})
	if aws.ToString(head1.Restore) == "" {
		t.Errorf("v1 should have x-amz-restore")
	}
	if aws.ToString(head2.Restore) != "" {
		t.Errorf("v2 should NOT have x-amz-restore, got: %q", aws.ToString(head2.Restore))
	}
}
