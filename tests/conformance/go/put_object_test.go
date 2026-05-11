package conformance

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	smithy "github.com/aws/smithy-go"
)

func TestPutObject_HappyPath(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "po")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed CreateBucket: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	out, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("hello.txt"),
		Body:   bytes.NewReader([]byte("hello world")),
	})
	if err != nil {
		t.Fatalf("PutObject: %v", err)
	}
	if out.ETag == nil || !strings.HasPrefix(*out.ETag, "\"") {
		t.Fatalf("expected quoted ETag, got %v", out.ETag)
	}
}

func TestPutObject_ContentTypeRoundTrip(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ct")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed CreateBucket: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket:      aws.String(bucket),
		Key:         aws.String("doc.json"),
		Body:        bytes.NewReader([]byte("{}")),
		ContentType: aws.String("application/json"),
	}); err != nil {
		t.Fatalf("PutObject: %v", err)
	}

	out, err := c.GetObject(context.Background(), &s3.GetObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("doc.json"),
	})
	if err != nil {
		t.Fatalf("GetObject: %v", err)
	}
	defer out.Body.Close()
	if out.ContentType == nil || *out.ContentType != "application/json" {
		t.Fatalf("ContentType round-trip failed: got %v", out.ContentType)
	}
}

func TestPutObject_UserMetadataRoundTrip(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "um")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed CreateBucket: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	meta := map[string]string{"foo": "bar", "alpha": "beta"}
	if _, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket:   aws.String(bucket),
		Key:      aws.String("k"),
		Body:     bytes.NewReader([]byte("x")),
		Metadata: meta,
	}); err != nil {
		t.Fatalf("PutObject: %v", err)
	}

	out, err := c.HeadObject(context.Background(), &s3.HeadObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("k"),
	})
	if err != nil {
		t.Fatalf("HeadObject: %v", err)
	}
	if v, ok := out.Metadata["foo"]; !ok || v != "bar" {
		t.Errorf("Metadata foo: got %q want bar", v)
	}
	if v, ok := out.Metadata["alpha"]; !ok || v != "beta" {
		t.Errorf("Metadata alpha: got %q want beta", v)
	}
}

func TestPutObject_LargeBody(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "lb")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed CreateBucket: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	body := bytes.Repeat([]byte{'A'}, 1024*1024) // 1 MiB
	if _, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("big"),
		Body:   bytes.NewReader(body),
	}); err != nil {
		t.Fatalf("PutObject: %v", err)
	}

	out, err := c.GetObject(context.Background(), &s3.GetObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("big"),
	})
	if err != nil {
		t.Fatalf("GetObject: %v", err)
	}
	defer out.Body.Close()
	buf := bytes.NewBuffer(nil)
	if _, err := buf.ReadFrom(out.Body); err != nil {
		t.Fatalf("read body: %v", err)
	}
	if !bytes.Equal(buf.Bytes(), body) {
		t.Fatalf("body mismatch: got %d bytes want %d", buf.Len(), len(body))
	}
}

func TestPutObject_MissingBucket(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "missing")
	_, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("k"),
		Body:   bytes.NewReader([]byte("x")),
	})
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
