// Package conformance asserts nanostack matches AWS S3 behaviour using the
// official aws-sdk-go-v2 client.
//
// This file keeps the basic NotImplemented contract for un-mapped
// operations. M3 routed all object operations; M4 routed ListObjects(V2).
// CreateMultipartUpload (POST /bucket/key?uploads) lands in M6 and is the
// current sentinel for the unrouted path.
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

func TestUnroutedOperationReturnsNotImplemented(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "unrouted")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed CreateBucket: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	// CreateMultipartUpload lands in M6 — `POST /bucket/key?uploads` is
	// currently unrouted and should surface as 501 NotImplemented.
	_, err := c.CreateMultipartUpload(context.Background(), &s3.CreateMultipartUploadInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("mp-key"),
	})
	if err == nil {
		t.Fatalf("expected NotImplemented error, got nil")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) {
		t.Fatalf("expected smithy.APIError, got %T: %v", err, err)
	}
	if apiErr.ErrorCode() != "NotImplemented" {
		t.Fatalf("ErrorCode mismatch: got %q want NotImplemented", apiErr.ErrorCode())
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 501 {
		t.Fatalf("expected HTTP 501, got %v", err)
	}
}
