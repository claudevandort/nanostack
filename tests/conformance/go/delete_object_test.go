package conformance

import (
	"context"
	"errors"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

func TestDeleteObject_HappyPath(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "do")
	defer cleanupBucket(t, c, bucket)
	seedObject(t, c, bucket, "k", []byte("v"))

	if _, err := c.DeleteObject(context.Background(), &s3.DeleteObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("k"),
	}); err != nil {
		t.Fatalf("DeleteObject: %v", err)
	}

	_, err := c.HeadObject(context.Background(), &s3.HeadObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("k"),
	})
	if err == nil {
		t.Fatalf("HeadObject should fail after Delete")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 404 {
		t.Fatalf("expected 404, got %v", err)
	}
}

// AWS DeleteObject is idempotent — deleting a missing key returns 204.
func TestDeleteObject_Idempotent(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "di")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed CreateBucket: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.DeleteObject(context.Background(), &s3.DeleteObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("never-existed"),
	}); err != nil {
		t.Fatalf("idempotent DeleteObject should succeed, got %v", err)
	}
}
