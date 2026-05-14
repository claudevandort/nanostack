package conformance

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

// UpdateObjectEncryption is a 2025 op not yet in the Go SDK version this
// repo pins (s3@v1.61.2). We exercise the op by sending a hand-signed
// SigV4 PUT to /bucket/key?encryption — confirms our routing + storage
// surface without needing an SDK upgrade.

func sigv4HmacSha256(key []byte, data string) []byte {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(data))
	return mac.Sum(nil)
}

func sigv4SigningKey(secret, dateStamp, region, service string) []byte {
	kDate := sigv4HmacSha256([]byte("AWS4"+secret), dateStamp)
	kRegion := sigv4HmacSha256(kDate, region)
	kService := sigv4HmacSha256(kRegion, service)
	return sigv4HmacSha256(kService, "aws4_request")
}

// putWithEncryptionXML signs and sends a PUT /bucket/key?encryption.
func putWithEncryptionXML(t *testing.T, endpoint, bucket, key, body string) (*http.Response, error) {
	t.Helper()
	accessKey := "test"
	secret := "test"
	region := "us-east-1"
	service := "s3"

	bodyHash := sha256.Sum256([]byte(body))
	bodyHashHex := hex.EncodeToString(bodyHash[:])

	now := time.Now().UTC()
	amzDate := now.Format("20060102T150405Z")
	dateStamp := now.Format("20060102")

	hostNoScheme := strings.TrimPrefix(strings.TrimPrefix(endpoint, "http://"), "https://")
	uri := fmt.Sprintf("/%s/%s", bucket, key)
	canonicalQueryString := "encryption="

	canonicalHeaders := fmt.Sprintf("host:%s\nx-amz-content-sha256:%s\nx-amz-date:%s\n", hostNoScheme, bodyHashHex, amzDate)
	signedHeaders := "host;x-amz-content-sha256;x-amz-date"

	canonicalRequest := fmt.Sprintf("PUT\n%s\n%s\n%s\n%s\n%s", uri, canonicalQueryString, canonicalHeaders, signedHeaders, bodyHashHex)
	hashedCanonicalRequest := sha256.Sum256([]byte(canonicalRequest))

	credentialScope := fmt.Sprintf("%s/%s/%s/aws4_request", dateStamp, region, service)
	stringToSign := fmt.Sprintf("AWS4-HMAC-SHA256\n%s\n%s\n%s", amzDate, credentialScope, hex.EncodeToString(hashedCanonicalRequest[:]))

	signingKey := sigv4SigningKey(secret, dateStamp, region, service)
	signature := hex.EncodeToString(sigv4HmacSha256(signingKey, stringToSign))

	authHeader := fmt.Sprintf("AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s",
		accessKey, credentialScope, signedHeaders, signature)

	url := fmt.Sprintf("%s/%s/%s?encryption", endpoint, bucket, key)
	req, _ := http.NewRequest("PUT", url, bytes.NewReader([]byte(body)))
	req.Header.Set("Host", hostNoScheme)
	req.Header.Set("x-amz-content-sha256", bodyHashHex)
	req.Header.Set("x-amz-date", amzDate)
	req.Header.Set("Authorization", authHeader)
	return http.DefaultClient.Do(req)
}

func TestUpdateObjectEncryption_AES256_HeadRoundTrip(t *testing.T) {
	c := newClient(t)
	endpoint := s3EndpointForTest()
	bucket := uniqueBucketName(t, "ue-aes")
	seedObject(t, c, bucket, "k", []byte("plain"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	body := "<ServerSideEncryption><Algorithm>AES256</Algorithm></ServerSideEncryption>"
	resp, err := putWithEncryptionXML(t, endpoint, bucket, "k", body)
	if err != nil {
		t.Fatalf("PUT ?encryption: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	head, err := c.HeadObject(context.Background(), &s3.HeadObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
	if err != nil {
		t.Fatalf("HeadObject: %v", err)
	}
	if string(head.ServerSideEncryption) != "AES256" {
		t.Errorf("expected SSE=AES256 in HEAD response, got %q", head.ServerSideEncryption)
	}
}

func s3EndpointForTest() string {
	if v := os.Getenv("NANOSTACK_ENDPOINT"); v != "" {
		return v
	}
	return "http://127.0.0.1:4577"
}
