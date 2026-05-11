package conformance

import (
	"context"
	"errors"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	smithy "github.com/aws/smithy-go"
)

func TestCreateBucket_HappyPath(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cb")
	defer cleanupBucket(t, c, bucket)

	out, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{
		Bucket: aws.String(bucket),
	})
	if err != nil {
		t.Fatalf("CreateBucket: %v", err)
	}
	if out.Location == nil || *out.Location == "" {
		t.Fatalf("expected non-empty Location, got %v", out.Location)
	}
}

func TestCreateBucket_DuplicateOwnedByYou(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cb-dup")
	defer cleanupBucket(t, c, bucket)

	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("first CreateBucket: %v", err)
	}

	_, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)})
	if err == nil {
		t.Fatalf("expected error on duplicate CreateBucket")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) {
		t.Fatalf("expected smithy.APIError, got %T: %v", err, err)
	}
	if apiErr.ErrorCode() != "BucketAlreadyOwnedByYou" {
		t.Fatalf("ErrorCode mismatch: got %q want BucketAlreadyOwnedByYou", apiErr.ErrorCode())
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 409 {
		t.Fatalf("expected HTTP 409, got %v", err)
	}
}

func TestCreateBucket_InvalidName(t *testing.T) {
	c := newClient(t)
	// Underscore is not allowed.
	_, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{
		Bucket: aws.String("Invalid_Name_Here"),
	})
	if err == nil {
		t.Fatalf("expected InvalidBucketName error")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) {
		t.Fatalf("expected smithy.APIError, got %T: %v", err, err)
	}
	if apiErr.ErrorCode() != "InvalidBucketName" {
		t.Fatalf("ErrorCode mismatch: got %q want InvalidBucketName", apiErr.ErrorCode())
	}
}

// cleanupBucket best-effort deletes a bucket. Used as a defer in happy-path
// tests so we leave no state behind for the next test or run.
func cleanupBucket(t *testing.T, c *s3.Client, bucket string) {
	t.Helper()
	_, _ = c.DeleteBucket(context.Background(), &s3.DeleteBucketInput{Bucket: aws.String(bucket)})
}
