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

func TestDeleteBucket_HappyPath(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "db")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed CreateBucket: %v", err)
	}

	if _, err := c.DeleteBucket(context.Background(), &s3.DeleteBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("DeleteBucket: %v", err)
	}

	// Confirm gone via HEAD.
	_, err := c.HeadBucket(context.Background(), &s3.HeadBucketInput{Bucket: aws.String(bucket)})
	if err == nil {
		t.Fatalf("expected HeadBucket to fail after DeleteBucket")
	}
}

func TestDeleteBucket_Missing(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "db-miss")
	_, err := c.DeleteBucket(context.Background(), &s3.DeleteBucketInput{Bucket: aws.String(bucket)})
	if err == nil {
		t.Fatalf("expected error for missing bucket")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) {
		t.Fatalf("expected smithy.APIError, got %T: %v", err, err)
	}
	if apiErr.ErrorCode() != "NoSuchBucket" {
		t.Fatalf("ErrorCode mismatch: got %q want NoSuchBucket", apiErr.ErrorCode())
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 404 {
		t.Fatalf("expected HTTP 404, got %v", err)
	}
}
