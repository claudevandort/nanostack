// Package conformance asserts nanostack matches AWS S3 behaviour using the
// official aws-sdk-go-v2 client.
//
// The test assumes a nanostack instance is already running at
// $NANOSTACK_ENDPOINT (default http://127.0.0.1:4577). CI starts the binary
// explicitly before invoking `go test`.
package conformance

import (
	"context"
	"errors"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	smithy "github.com/aws/smithy-go"
)

func endpoint() string {
	if e := os.Getenv("NANOSTACK_ENDPOINT"); e != "" {
		return e
	}
	return "http://127.0.0.1:4577"
}

func newClient(t *testing.T) *s3.Client {
	t.Helper()
	return s3.New(s3.Options{
		Region:       "us-east-1",
		Credentials:  credentials.NewStaticCredentialsProvider("test", "test", ""),
		BaseEndpoint: aws.String(endpoint()),
		UsePathStyle: true,
		HTTPClient:   &http.Client{Timeout: 5 * time.Second},
	})
}

// M0 acceptance: every operation must return a NotImplemented (HTTP 501) AWS
// error response that the official SDK parses as a smithy.APIError.
func TestCreateBucketReturnsNotImplemented(t *testing.T) {
	c := newClient(t)
	_, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{
		Bucket: aws.String("nanostack-m0-test"),
	})
	if err == nil {
		t.Fatalf("expected NotImplemented error, got nil")
	}

	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) {
		t.Fatalf("expected smithy.APIError, got %T: %v", err, err)
	}
	if apiErr.ErrorCode() != "NotImplemented" {
		t.Fatalf("ErrorCode mismatch: got %q want %q", apiErr.ErrorCode(), "NotImplemented")
	}
	if !strings.Contains(apiErr.ErrorMessage(), "not implemented") {
		t.Fatalf("ErrorMessage missing expected substring: %q", apiErr.ErrorMessage())
	}

	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) {
		t.Fatalf("expected awshttp.ResponseError, got %T", err)
	}
	if respErr.HTTPStatusCode() != 501 {
		t.Fatalf("HTTP status mismatch: got %d want 501", respErr.HTTPStatusCode())
	}
	if rid := respErr.ServiceRequestID(); rid == "" {
		t.Fatalf("expected non-empty x-amz-request-id header, got empty")
	}
}

func TestHeadBucketReturnsNotImplemented(t *testing.T) {
	c := newClient(t)
	_, err := c.HeadBucket(context.Background(), &s3.HeadBucketInput{
		Bucket: aws.String("nanostack-m0-test"),
	})
	if err == nil {
		t.Fatalf("expected error, got nil")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) {
		t.Fatalf("expected awshttp.ResponseError, got %T: %v", err, err)
	}
	if respErr.HTTPStatusCode() != 501 {
		t.Fatalf("HTTP status mismatch: got %d want 501", respErr.HTTPStatusCode())
	}
}
