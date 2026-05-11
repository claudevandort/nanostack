package conformance

import (
	"context"
	"errors"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

func TestHeadBucket_Existing(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "hb")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed CreateBucket: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.HeadBucket(context.Background(), &s3.HeadBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("HeadBucket: %v", err)
	}
}

func TestHeadBucket_Missing(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "hb-miss")
	// Do not create.
	_, err := c.HeadBucket(context.Background(), &s3.HeadBucketInput{Bucket: aws.String(bucket)})
	if err == nil {
		t.Fatalf("expected error for missing bucket")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) {
		t.Fatalf("expected awshttp.ResponseError, got %T: %v", err, err)
	}
	if respErr.HTTPStatusCode() != 404 {
		t.Fatalf("expected HTTP 404, got %d", respErr.HTTPStatusCode())
	}
}
