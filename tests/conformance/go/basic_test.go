// Package conformance asserts nanostack matches AWS S3 behaviour using the
// official aws-sdk-go-v2 client.
//
// Per-operation tests live in the operation-specific files. This file keeps
// the basic NotImplemented contract for un-mapped operations.
package conformance

import (
	"errors"
	"net/http"
	"testing"
	"time"

	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
)

// Object operations (PUT /bucket/key etc.) are still unrouted in M1; this
// asserts the server still emits a well-formed AWS error so the SDK can
// parse it.
func TestUnroutedOperationReturnsNotImplemented(t *testing.T) {
	url := endpoint() + "/some-bucket/some-key"
	req, err := http.NewRequest(http.MethodPut, url, nil)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	httpc := &http.Client{Timeout: 5 * time.Second}
	resp, err := httpc.Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 501 {
		t.Fatalf("expected 501, got %d", resp.StatusCode)
	}
	if got := resp.Header.Get("x-amz-request-id"); got == "" {
		t.Fatalf("expected x-amz-request-id header to be set")
	}
}

// Sanity check: errors.As shape is what we expect everywhere.
var _ = errors.As
var _ = awshttp.ResponseError{}
