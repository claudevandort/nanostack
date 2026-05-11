// SigV4 conformance: verifies authentication behaviour for both header
// auth and presigned URLs. The "custom-header presigned URL" tests are
// the regression for the LocalStack bug we exist to fix
// (#5269, #4133, #10844): a header listed in X-Amz-SignedHeaders that
// is absent from the request must yield a clean AWS error, never a
// 5xx panic.
package conformance

import (
	"context"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	v4 "github.com/aws/aws-sdk-go-v2/aws/signer/v4"
)

const sha256Empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

func testCreds() aws.Credentials {
	return aws.Credentials{AccessKeyID: "test", SecretAccessKey: "test"}
}

func TestAnonymousRequestIsDenied(t *testing.T) {
	req, _ := http.NewRequest(http.MethodGet, endpoint()+"/", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 403 {
		t.Fatalf("expected 403 for anonymous request, got %d", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(body), "<Code>AccessDenied</Code>") {
		t.Fatalf("expected AccessDenied body, got %s", body)
	}
}

func TestBadSignatureIsRejected(t *testing.T) {
	// Sign a HEAD on the root with the SDK signer, tamper the signature,
	// replay. Expect 403 SignatureDoesNotMatch.
	signer := v4.NewSigner()
	req, _ := http.NewRequest(http.MethodGet, endpoint()+"/", nil)
	req.Host = endpointHost() // Host header used by signing
	if err := signer.SignHTTP(context.Background(), testCreds(), req, sha256Empty, "s3", "us-east-1", time.Now()); err != nil {
		t.Fatalf("SignHTTP: %v", err)
	}
	auth := req.Header.Get("Authorization")
	if !strings.Contains(auth, "Signature=") {
		t.Fatalf("expected Signature= in Authorization: %s", auth)
	}
	// Flip the last hex char of the signature.
	idx := strings.Index(auth, "Signature=")
	tampered := auth[:idx+len("Signature=")] + flipLastHex(auth[idx+len("Signature="):])
	req.Header.Set("Authorization", tampered)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 403 {
		t.Fatalf("expected 403 tampered, got %d", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(body), "<Code>SignatureDoesNotMatch</Code>") {
		t.Fatalf("expected SignatureDoesNotMatch, got: %s", body)
	}
}

// Object operations are still unrouted in M2 — but auth still must pass.
// A presigned HEAD on /bucket/key resolves to 501 NotImplemented (proving
// SigV4 succeeded; failure would be 403 AccessDenied / SignatureDoesNotMatch).
func TestPresignedHappyPath(t *testing.T) {
	signer := v4.NewSigner()
	req, _ := http.NewRequest(http.MethodHead, endpoint()+"/test-bucket/test-key?X-Amz-Expires=3600", nil)
	req.Host = endpointHost()
	signedURL, _, err := signer.PresignHTTP(context.Background(), testCreds(), req, "UNSIGNED-PAYLOAD", "s3", "us-east-1", time.Now())
	if err != nil {
		t.Fatalf("PresignHTTP: %v", err)
	}
	resp, err := http.DefaultClient.Head(signedURL)
	if err != nil {
		t.Fatalf("head: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 501 {
		t.Fatalf("expected 501 (auth passed, op unrouted in M2), got %d", resp.StatusCode)
	}
}

func TestPresignedExpired(t *testing.T) {
	signer := v4.NewSigner()
	req, _ := http.NewRequest(http.MethodHead, endpoint()+"/test-bucket/test-key?X-Amz-Expires=1", nil)
	req.Host = endpointHost()
	// Sign as if 5 seconds ago — already expired against a 1-second window.
	signedURL, _, err := signer.PresignHTTP(context.Background(), testCreds(), req, "UNSIGNED-PAYLOAD", "s3", "us-east-1", time.Now().Add(-5*time.Second))
	if err != nil {
		t.Fatalf("PresignHTTP: %v", err)
	}
	resp, err := http.DefaultClient.Head(signedURL)
	if err != nil {
		t.Fatalf("head: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 403 {
		t.Fatalf("expected 403 for expired presigned URL, got %d", resp.StatusCode)
	}
}

func TestPresignedCustomHeaderHappy(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "pch")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed CreateBucket: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	signedURL := presignWithHeader(t, http.MethodHead, "/"+bucket, "x-nano-custom", "value-1")

	req, _ := http.NewRequest(http.MethodHead, signedURL, nil)
	req.Header.Set("x-nano-custom", "value-1")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected 200 (HeadBucket with signed custom header), got %d: %s", resp.StatusCode, body)
	}
}

// The LocalStack regression case: same presigned URL, request sent WITHOUT
// the header that's listed in X-Amz-SignedHeaders. Must produce a clean
// 403 with an AWS error body — never a 5xx or partial response.
func TestPresignedCustomHeaderMissing(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "pcm")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed CreateBucket: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	// Use GET so the AWS error body is delivered (HEAD must suppress it
	// per RFC 9110). Status code alone is the regression assertion: the
	// LocalStack bug surfaces as a 5xx panic; we expect a clean 403.
	signedURL := presignWithHeader(t, http.MethodGet, "/"+bucket, "x-nano-custom", "value-1")
	resp, err := http.DefaultClient.Get(signedURL)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 403 {
		t.Fatalf("expected 403 for missing signed header, got %d", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	bs := string(body)
	if !strings.Contains(bs, "<Code>SignatureDoesNotMatch</Code>") {
		t.Fatalf("expected SignatureDoesNotMatch body, got: %s", bs)
	}
}

func TestNoAuthFlagAcceptsAnonymous(t *testing.T) {
	binPath := os.Getenv("NANOSTACK_BIN")
	if binPath == "" {
		t.Skip("NANOSTACK_BIN not set; skipping --no-auth subprocess test")
	}
	port := "14999"
	cmd := exec.Command(binPath, "--port", port, "--ephemeral", "--no-auth")
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatalf("start: %v", err)
	}
	defer func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()

	// Wait for the listener.
	url := "http://127.0.0.1:" + port + "/"
	for i := 0; i < 50; i++ {
		resp, err := http.Get(url)
		if err == nil {
			defer resp.Body.Close()
			if resp.StatusCode == 200 {
				return
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("nanostack --no-auth did not accept anonymous GET / within 5s")
}

// ---------------------------------------------------------------------------
// Helpers

func flipLastHex(sig string) string {
	if len(sig) == 0 {
		return sig
	}
	last := sig[len(sig)-1]
	var alt byte
	switch last {
	case '0':
		alt = '1'
	case 'f':
		alt = 'e'
	default:
		alt = '0'
	}
	return sig[:len(sig)-1] + string(alt)
}

// presignWithHeader signs a request URL with an additional header in
// SignedHeaders. The Go SDK's presigner doesn't natively expose this;
// we drop to the v4 signer directly.
func presignWithHeader(t *testing.T, method, path, headerName, headerValue string) string {
	t.Helper()
	signer := v4.NewSigner()
	req, err := http.NewRequest(method, endpoint()+path+"?X-Amz-Expires=3600", nil)
	if err != nil {
		t.Fatalf("NewRequest: %v", err)
	}
	req.Host = endpointHost()
	req.Header.Set(headerName, headerValue)
	signedURL, _, err := signer.PresignHTTP(context.Background(), testCreds(), req, "UNSIGNED-PAYLOAD", "s3", "us-east-1", time.Now())
	if err != nil {
		t.Fatalf("PresignHTTP: %v", err)
	}
	return signedURL
}
