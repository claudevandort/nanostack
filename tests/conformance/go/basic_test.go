// Package conformance asserts nanostack matches AWS S3 behaviour using the
// official aws-sdk-go-v2 client.
//
// This file keeps the basic NotImplemented contract for un-mapped
// operations. M2 added SigV4 verification: anonymous requests are now
// denied, so we exercise the unrouted-op path with a signed PutObject
// (object operations are M3's territory; they currently resolve to
// `unknown` → 501).
package conformance

import (
	"bytes"
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
	// PutObject is an object op — currently unrouted; expect a signed
	// request to land in the s3.unknown branch and surface as 501.
	_, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String("any-bucket"),
		Key:    aws.String("any-key"),
		Body:   bytes.NewReader([]byte("hello")),
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
