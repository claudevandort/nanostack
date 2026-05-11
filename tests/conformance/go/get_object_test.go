package conformance

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	v4 "github.com/aws/aws-sdk-go-v2/aws/signer/v4"
	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

func seedObject(t *testing.T, c *s3.Client, bucket, key string, body []byte) {
	t.Helper()
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed CreateBucket: %v", err)
	}
	if _, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String(key),
		Body:   bytes.NewReader(body),
	}); err != nil {
		t.Fatalf("seed PutObject: %v", err)
	}
}

func TestGetObject_FullBody(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "go")
	defer cleanupBucket(t, c, bucket)
	body := []byte("hello world this is nanostack")
	seedObject(t, c, bucket, "k", body)

	out, err := c.GetObject(context.Background(), &s3.GetObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("k"),
	})
	if err != nil {
		t.Fatalf("GetObject: %v", err)
	}
	defer out.Body.Close()

	if out.AcceptRanges == nil || *out.AcceptRanges != "bytes" {
		t.Fatalf("expected Accept-Ranges: bytes, got %v", out.AcceptRanges)
	}

	buf := bytes.NewBuffer(nil)
	if _, err := buf.ReadFrom(out.Body); err != nil {
		t.Fatalf("read: %v", err)
	}
	if !bytes.Equal(buf.Bytes(), body) {
		t.Fatalf("body mismatch")
	}
}

func TestGetObject_RangePrefix(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "rp")
	defer cleanupBucket(t, c, bucket)
	body := []byte("0123456789abcdef")
	seedObject(t, c, bucket, "k", body)

	out, err := c.GetObject(context.Background(), &s3.GetObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("k"),
		Range:  aws.String("bytes=0-4"),
	})
	if err != nil {
		t.Fatalf("GetObject range: %v", err)
	}
	defer out.Body.Close()

	if out.ContentRange == nil || *out.ContentRange != fmt.Sprintf("bytes 0-4/%d", len(body)) {
		t.Fatalf("ContentRange mismatch: got %v want bytes 0-4/%d", out.ContentRange, len(body))
	}
	got, _ := io.ReadAll(out.Body)
	if string(got) != "01234" {
		t.Fatalf("body got %q want %q", got, "01234")
	}
}

func TestGetObject_RangeSuffix(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "rs")
	defer cleanupBucket(t, c, bucket)
	body := []byte("0123456789abcdef") // 16 bytes
	seedObject(t, c, bucket, "k", body)

	out, err := c.GetObject(context.Background(), &s3.GetObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("k"),
		Range:  aws.String("bytes=-5"),
	})
	if err != nil {
		t.Fatalf("GetObject suffix range: %v", err)
	}
	defer out.Body.Close()
	got, _ := io.ReadAll(out.Body)
	if string(got) != "bcdef" {
		t.Fatalf("got %q want %q", got, "bcdef")
	}
}

func TestGetObject_OpenRange(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "or")
	defer cleanupBucket(t, c, bucket)
	body := []byte("0123456789abcdef")
	seedObject(t, c, bucket, "k", body)

	out, err := c.GetObject(context.Background(), &s3.GetObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("k"),
		Range:  aws.String("bytes=10-"),
	})
	if err != nil {
		t.Fatalf("GetObject open range: %v", err)
	}
	defer out.Body.Close()
	got, _ := io.ReadAll(out.Body)
	if string(got) != "abcdef" {
		t.Fatalf("got %q want %q", got, "abcdef")
	}
}

func TestGetObject_OutOfRange(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ox")
	defer cleanupBucket(t, c, bucket)
	body := []byte("short")
	seedObject(t, c, bucket, "k", body)

	// The SDK doesn't surface 416 cleanly; sign the raw HTTP ourselves so
	// we can read the status verbatim.
	signer := v4.NewSigner()
	req, _ := http.NewRequest("GET", endpoint()+"/"+bucket+"/k", nil)
	req.Host = endpointHost()
	req.Header.Set("Range", "bytes=999-")
	if err := signer.SignHTTP(context.Background(), testCreds(), req, sha256Empty, "s3", "us-east-1", time.Now()); err != nil {
		t.Fatalf("sign: %v", err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 416 {
		t.Fatalf("expected 416 for out-of-range, got %d", resp.StatusCode)
	}
}

func TestGetObject_MissingKey(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "mk")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed CreateBucket: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	_, err := c.GetObject(context.Background(), &s3.GetObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("nope"),
	})
	if err == nil {
		t.Fatalf("expected NoSuchKey")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 404 {
		t.Fatalf("expected HTTP 404, got %v", err)
	}
}
