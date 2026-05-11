// Package conformance asserts nanostack matches AWS S3 behaviour using the
// official aws-sdk-go-v2 client.
//
// This file keeps the basic NotImplemented contract for un-mapped
// operations. M3 routed all object operations; the remaining unrouted
// path in M3 is ListObjects(V2), which is M4's territory.
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

	// ListObjectsV2 lands in M4 — `GET /bucket?list-type=2` is currently
	// unrouted and should surface as 501 NotImplemented.
	_, err := c.ListObjectsV2(context.Background(), &s3.ListObjectsV2Input{
		Bucket: aws.String(bucket),
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
