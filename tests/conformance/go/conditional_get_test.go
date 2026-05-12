package conformance

import (
	"bytes"
	"context"
	"errors"
	"io"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

func seedAndGetEtag(t *testing.T, c *s3.Client, bucket, key string, body []byte) string {
	t.Helper()
	seedObject(t, c, bucket, key, body)
	head, err := c.HeadObject(context.Background(), &s3.HeadObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String(key),
	})
	if err != nil {
		t.Fatalf("seed Head: %v", err)
	}
	return aws.ToString(head.ETag)
}

func TestConditionalGet_IfMatch_Mismatch(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cg-ifm")
	_ = seedAndGetEtag(t, c, bucket, "k", []byte("x"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	_, err := c.GetObject(context.Background(), &s3.GetObjectInput{
		Bucket:  aws.String(bucket),
		Key:     aws.String("k"),
		IfMatch: aws.String(`"deadbeef"`),
	})
	if err == nil {
		t.Fatal("expected 412 PreconditionFailed, got nil")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 412 {
		t.Fatalf("expected HTTP 412, got %v", err)
	}
}

func TestConditionalGet_IfNoneMatch_Match(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cg-inm")
	etag := seedAndGetEtag(t, c, bucket, "k", []byte("x"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	// The SDK turns 304 into a NotModified error; check via HTTP status.
	_, err := c.GetObject(context.Background(), &s3.GetObjectInput{
		Bucket:      aws.String(bucket),
		Key:         aws.String("k"),
		IfNoneMatch: aws.String(etag),
	})
	if err == nil {
		t.Fatal("expected 304 NotModified, got nil")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 304 {
		t.Fatalf("expected HTTP 304, got %v", err)
	}
}

func TestConditionalGet_IfModifiedSince_Future_Returns304(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cg-ims")
	_ = seedAndGetEtag(t, c, bucket, "k", []byte("x"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	future := time.Now().Add(1 * time.Hour)
	_, err := c.GetObject(context.Background(), &s3.GetObjectInput{
		Bucket:          aws.String(bucket),
		Key:             aws.String("k"),
		IfModifiedSince: aws.Time(future),
	})
	if err == nil {
		t.Fatal("expected 304, got nil")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 304 {
		t.Fatalf("expected HTTP 304, got %v", err)
	}
}

func TestConditionalGet_IfUnmodifiedSince_Past_Returns412(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cg-ius")
	_ = seedAndGetEtag(t, c, bucket, "k", []byte("x"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	past := time.Unix(0, 0)
	_, err := c.GetObject(context.Background(), &s3.GetObjectInput{
		Bucket:            aws.String(bucket),
		Key:               aws.String("k"),
		IfUnmodifiedSince: aws.Time(past),
	})
	if err == nil {
		t.Fatal("expected 412, got nil")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 412 {
		t.Fatalf("expected HTTP 412, got %v", err)
	}
}

func TestConditionalGet_IfMatch_HappyPath_BodyReturned(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cg-ifm-ok")
	etag := seedAndGetEtag(t, c, bucket, "k", []byte("happy"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	out, err := c.GetObject(context.Background(), &s3.GetObjectInput{
		Bucket:  aws.String(bucket),
		Key:     aws.String("k"),
		IfMatch: aws.String(etag),
	})
	if err != nil {
		t.Fatalf("GET IfMatch matching: %v", err)
	}
	defer out.Body.Close()
	got, _ := io.ReadAll(out.Body)
	if !bytes.Equal(got, []byte("happy")) {
		t.Fatalf("body mismatch")
	}
}

func TestConditionalHead_IfNoneMatch_Match_Returns304(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ch-inm")
	etag := seedAndGetEtag(t, c, bucket, "k", []byte("x"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	_, err := c.HeadObject(context.Background(), &s3.HeadObjectInput{
		Bucket:      aws.String(bucket),
		Key:         aws.String("k"),
		IfNoneMatch: aws.String(etag),
	})
	if err == nil {
		t.Fatal("expected 304, got nil")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 304 {
		t.Fatalf("expected HTTP 304 on HEAD, got %v", err)
	}
}
