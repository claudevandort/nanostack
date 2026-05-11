package conformance

import (
	"bytes"
	"context"
	"errors"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

func TestHeadObject_HappyPath(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ho")
	defer cleanupBucket(t, c, bucket)
	body := []byte("hello world")
	seedObject(t, c, bucket, "k", body)

	out, err := c.HeadObject(context.Background(), &s3.HeadObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("k"),
	})
	if err != nil {
		t.Fatalf("HeadObject: %v", err)
	}
	if out.ContentLength == nil || *out.ContentLength != int64(len(body)) {
		t.Fatalf("ContentLength mismatch: got %v want %d", out.ContentLength, len(body))
	}
	if out.AcceptRanges == nil || *out.AcceptRanges != "bytes" {
		t.Fatalf("expected Accept-Ranges: bytes, got %v", out.AcceptRanges)
	}
	if out.ETag == nil {
		t.Fatalf("expected ETag header")
	}
	if out.LastModified == nil {
		t.Fatalf("expected Last-Modified")
	}
}

func TestHeadObject_MissingKey(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "hm")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed CreateBucket: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	_, err := c.HeadObject(context.Background(), &s3.HeadObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("nope"),
	})
	if err == nil {
		t.Fatalf("expected error")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 404 {
		t.Fatalf("expected HTTP 404, got %v", err)
	}
}

// Sanity: HEAD body is empty (RFC 9110) but Content-Length still matches.
func TestHeadObject_NoBody(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "hn")
	defer cleanupBucket(t, c, bucket)
	body := bytes.Repeat([]byte{'X'}, 100)
	seedObject(t, c, bucket, "k", body)

	out, err := c.HeadObject(context.Background(), &s3.HeadObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("k"),
	})
	if err != nil {
		t.Fatalf("HeadObject: %v", err)
	}
	if out.ContentLength == nil || *out.ContentLength != 100 {
		t.Fatalf("ContentLength should equal 100 (the would-be GET body size), got %v", out.ContentLength)
	}
}
