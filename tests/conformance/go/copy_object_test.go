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
	smithy "github.com/aws/smithy-go"
)

func readGetBody(t *testing.T, c *s3.Client, bucket, key string) []byte {
	t.Helper()
	out, err := c.GetObject(context.Background(), &s3.GetObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String(key),
	})
	if err != nil {
		t.Fatalf("GetObject %s/%s: %v", bucket, key, err)
	}
	defer out.Body.Close()
	body, err := io.ReadAll(out.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	return body
}

func TestCopyObject_SameBucketHappy(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cp-same")
	seedObject(t, c, bucket, "src", []byte("hello copy"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("src")})
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("dst")})
		cleanupBucket(t, c, bucket)
	}()

	out, err := c.CopyObject(context.Background(), &s3.CopyObjectInput{
		Bucket:     aws.String(bucket),
		Key:        aws.String("dst"),
		CopySource: aws.String(bucket + "/src"),
	})
	if err != nil {
		t.Fatalf("CopyObject: %v", err)
	}
	if out.CopyObjectResult == nil || out.CopyObjectResult.ETag == nil {
		t.Fatalf("missing CopyObjectResult.ETag")
	}
	body := readGetBody(t, c, bucket, "dst")
	if !bytes.Equal(body, []byte("hello copy")) {
		t.Fatalf("body mismatch: got %q", body)
	}
}

func TestCopyObject_CrossBucketPreservesMetadata(t *testing.T) {
	c := newClient(t)
	src := uniqueBucketName(t, "cp-src")
	dst := uniqueBucketName(t, "cp-dst")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(src)}); err != nil {
		t.Fatalf("seed src: %v", err)
	}
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(dst)}); err != nil {
		t.Fatalf("seed dst: %v", err)
	}
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(src), Key: aws.String("k")})
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(dst), Key: aws.String("k")})
		cleanupBucket(t, c, src)
		cleanupBucket(t, c, dst)
	}()

	if _, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket:      aws.String(src),
		Key:         aws.String("k"),
		Body:        bytes.NewReader([]byte("payload")),
		ContentType: aws.String("application/x-foo"),
		Metadata:    map[string]string{"author": "claude"},
	}); err != nil {
		t.Fatalf("seed Put: %v", err)
	}

	if _, err := c.CopyObject(context.Background(), &s3.CopyObjectInput{
		Bucket:     aws.String(dst),
		Key:        aws.String("k"),
		CopySource: aws.String(src + "/k"),
	}); err != nil {
		t.Fatalf("CopyObject: %v", err)
	}

	head, err := c.HeadObject(context.Background(), &s3.HeadObjectInput{
		Bucket: aws.String(dst),
		Key:    aws.String("k"),
	})
	if err != nil {
		t.Fatalf("HeadObject dst: %v", err)
	}
	if aws.ToString(head.ContentType) != "application/x-foo" {
		t.Errorf("ContentType not carried: got %q", aws.ToString(head.ContentType))
	}
	if got := head.Metadata["author"]; got != "claude" {
		t.Errorf("metadata 'author' missing: got %v", head.Metadata)
	}
}

func TestCopyObject_ReplaceDirective(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cp-rep")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("src")})
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("dst")})
		cleanupBucket(t, c, bucket)
	}()

	if _, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket:      aws.String(bucket),
		Key:         aws.String("src"),
		Body:        bytes.NewReader([]byte("payload")),
		ContentType: aws.String("text/plain"),
		Metadata:    map[string]string{"old": "yes"},
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	if _, err := c.CopyObject(context.Background(), &s3.CopyObjectInput{
		Bucket:            aws.String(bucket),
		Key:               aws.String("dst"),
		CopySource:        aws.String(bucket + "/src"),
		MetadataDirective: "REPLACE",
		ContentType:       aws.String("application/json"),
		Metadata:          map[string]string{"new": "ok"},
	}); err != nil {
		t.Fatalf("CopyObject REPLACE: %v", err)
	}

	head, err := c.HeadObject(context.Background(), &s3.HeadObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("dst"),
	})
	if err != nil {
		t.Fatalf("Head dst: %v", err)
	}
	if aws.ToString(head.ContentType) != "application/json" {
		t.Errorf("REPLACE didn't change ContentType: got %q", aws.ToString(head.ContentType))
	}
	if _, ok := head.Metadata["old"]; ok {
		t.Errorf("REPLACE leaked source metadata: %v", head.Metadata)
	}
	if got := head.Metadata["new"]; got != "ok" {
		t.Errorf("REPLACE missing new metadata: %v", head.Metadata)
	}
}

func TestCopyObject_SourceMissing(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cp-srcmiss")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	_, err := c.CopyObject(context.Background(), &s3.CopyObjectInput{
		Bucket:     aws.String(bucket),
		Key:        aws.String("dst"),
		CopySource: aws.String(bucket + "/no-such-source"),
	})
	if err == nil {
		t.Fatal("expected NoSuchKey, got nil")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) || apiErr.ErrorCode() != "NoSuchKey" {
		t.Fatalf("expected NoSuchKey, got %v", err)
	}
}

func TestCopyObject_InvalidMetadataDirective(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cp-baddir")
	seedObject(t, c, bucket, "src", []byte("x"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("src")})
		cleanupBucket(t, c, bucket)
	}()

	_, err := c.CopyObject(context.Background(), &s3.CopyObjectInput{
		Bucket:            aws.String(bucket),
		Key:               aws.String("dst"),
		CopySource:        aws.String(bucket + "/src"),
		MetadataDirective: "NEITHER",
	})
	if err == nil {
		t.Fatal("expected InvalidArgument, got nil")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) || apiErr.ErrorCode() != "InvalidArgument" {
		t.Fatalf("expected InvalidArgument, got %v", err)
	}
}

func TestCopyObject_CopySourceIfMatch_OK(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cp-csim")
	seedObject(t, c, bucket, "src", []byte("x"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("src")})
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("dst")})
		cleanupBucket(t, c, bucket)
	}()

	head, err := c.HeadObject(context.Background(), &s3.HeadObjectInput{Bucket: aws.String(bucket), Key: aws.String("src")})
	if err != nil {
		t.Fatalf("Head src: %v", err)
	}
	etag := aws.ToString(head.ETag)

	if _, err := c.CopyObject(context.Background(), &s3.CopyObjectInput{
		Bucket:            aws.String(bucket),
		Key:               aws.String("dst"),
		CopySource:        aws.String(bucket + "/src"),
		CopySourceIfMatch: aws.String(etag),
	}); err != nil {
		t.Fatalf("CopyObject with matching CopySourceIfMatch: %v", err)
	}
}

func TestCopyObject_CopySourceIfMatch_Mismatch(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cp-csimno")
	seedObject(t, c, bucket, "src", []byte("x"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("src")})
		cleanupBucket(t, c, bucket)
	}()

	_, err := c.CopyObject(context.Background(), &s3.CopyObjectInput{
		Bucket:            aws.String(bucket),
		Key:               aws.String("dst"),
		CopySource:        aws.String(bucket + "/src"),
		CopySourceIfMatch: aws.String(`"deadbeef"`),
	})
	if err == nil {
		t.Fatal("expected PreconditionFailed, got nil")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 412 {
		t.Fatalf("expected HTTP 412, got %v", err)
	}
}

func TestCopyObject_CopySourceIfNoneMatch_Mismatch(t *testing.T) {
	// If-None-Match with matching etag → 412 (precondition failed on source).
	c := newClient(t)
	bucket := uniqueBucketName(t, "cp-csinm")
	seedObject(t, c, bucket, "src", []byte("x"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("src")})
		cleanupBucket(t, c, bucket)
	}()

	head, _ := c.HeadObject(context.Background(), &s3.HeadObjectInput{Bucket: aws.String(bucket), Key: aws.String("src")})
	etag := aws.ToString(head.ETag)

	_, err := c.CopyObject(context.Background(), &s3.CopyObjectInput{
		Bucket:                aws.String(bucket),
		Key:                   aws.String("dst"),
		CopySource:            aws.String(bucket + "/src"),
		CopySourceIfNoneMatch: aws.String(etag),
	})
	if err == nil {
		t.Fatal("expected PreconditionFailed, got nil")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 412 {
		t.Fatalf("expected HTTP 412, got %v", err)
	}
}

func TestCopyObject_CopySourceIfUnmodifiedSince_OK(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cp-csius")
	seedObject(t, c, bucket, "src", []byte("x"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("src")})
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("dst")})
		cleanupBucket(t, c, bucket)
	}()

	// One hour in the future — source was modified strictly before this.
	future := time.Now().Add(1 * time.Hour)
	if _, err := c.CopyObject(context.Background(), &s3.CopyObjectInput{
		Bucket:                       aws.String(bucket),
		Key:                          aws.String("dst"),
		CopySource:                   aws.String(bucket + "/src"),
		CopySourceIfUnmodifiedSince: aws.Time(future),
	}); err != nil {
		t.Fatalf("CopyObject CopySourceIfUnmodifiedSince(future): %v", err)
	}
}

func TestCopyObject_CopySourceIfModifiedSince_Fail(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cp-csims")
	seedObject(t, c, bucket, "src", []byte("x"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("src")})
		cleanupBucket(t, c, bucket)
	}()

	// One hour in the future — source has NOT been modified since then.
	future := time.Now().Add(1 * time.Hour)
	_, err := c.CopyObject(context.Background(), &s3.CopyObjectInput{
		Bucket:                     aws.String(bucket),
		Key:                        aws.String("dst"),
		CopySource:                 aws.String(bucket + "/src"),
		CopySourceIfModifiedSince: aws.Time(future),
	})
	if err == nil {
		t.Fatal("expected PreconditionFailed, got nil")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 412 {
		t.Fatalf("expected HTTP 412, got %v", err)
	}
}
