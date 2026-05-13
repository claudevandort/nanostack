package conformance

import (
	"bytes"
	"context"
	"errors"
	"io"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

// minPartSize: every non-final part must be ≥ 5 MiB per AWS S3.
const minPartSize = 5 * 1024 * 1024

func makePayload(size int, b byte) []byte {
	out := make([]byte, size)
	for i := range out {
		out[i] = b
	}
	return out
}

func TestMultipartUpload_HappyPath_TwoParts(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "mpu-ok")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	init, err := c.CreateMultipartUpload(context.Background(), &s3.CreateMultipartUploadInput{
		Bucket:      aws.String(bucket),
		Key:         aws.String("k"),
		ContentType: aws.String("application/x-foo"),
		Metadata:    map[string]string{"author": "claude"},
	})
	if err != nil {
		t.Fatalf("CreateMultipartUpload: %v", err)
	}
	uploadId := aws.ToString(init.UploadId)
	if uploadId == "" {
		t.Fatal("missing UploadId")
	}

	part1 := makePayload(minPartSize, 'A')
	part2 := []byte("tail")

	p1, err := c.UploadPart(context.Background(), &s3.UploadPartInput{
		Bucket:     aws.String(bucket),
		Key:        aws.String("k"),
		UploadId:   aws.String(uploadId),
		PartNumber: aws.Int32(1),
		Body:       bytes.NewReader(part1),
	})
	if err != nil {
		t.Fatalf("UploadPart 1: %v", err)
	}
	p2, err := c.UploadPart(context.Background(), &s3.UploadPartInput{
		Bucket:     aws.String(bucket),
		Key:        aws.String("k"),
		UploadId:   aws.String(uploadId),
		PartNumber: aws.Int32(2),
		Body:       bytes.NewReader(part2),
	})
	if err != nil {
		t.Fatalf("UploadPart 2: %v", err)
	}

	cmpu, err := c.CompleteMultipartUpload(context.Background(), &s3.CompleteMultipartUploadInput{
		Bucket:   aws.String(bucket),
		Key:      aws.String("k"),
		UploadId: aws.String(uploadId),
		MultipartUpload: &types.CompletedMultipartUpload{
			Parts: []types.CompletedPart{
				{ETag: p1.ETag, PartNumber: aws.Int32(1)},
				{ETag: p2.ETag, PartNumber: aws.Int32(2)},
			},
		},
	})
	if err != nil {
		t.Fatalf("CompleteMultipartUpload: %v", err)
	}
	if cmpu.ETag == nil || !strings.Contains(*cmpu.ETag, "-2\"") {
		t.Fatalf("expected multipart ETag ending in -2, got %v", cmpu.ETag)
	}

	// Verify the merged body matches part1 || part2.
	got, err := c.GetObject(context.Background(), &s3.GetObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
	if err != nil {
		t.Fatalf("GetObject: %v", err)
	}
	defer got.Body.Close()
	body, _ := io.ReadAll(got.Body)
	if len(body) != len(part1)+len(part2) {
		t.Fatalf("merged size mismatch: got %d want %d", len(body), len(part1)+len(part2))
	}
	if !bytes.Equal(body[:len(part1)], part1) || !bytes.Equal(body[len(part1):], part2) {
		t.Fatal("merged body content mismatch")
	}
	if aws.ToString(got.ContentType) != "application/x-foo" {
		t.Errorf("ContentType not preserved: %q", aws.ToString(got.ContentType))
	}
	if got.Metadata["author"] != "claude" {
		t.Errorf("metadata not preserved: %v", got.Metadata)
	}
}

func TestMultipartUpload_SinglePart_AnySize(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "mpu-1part")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	init, _ := c.CreateMultipartUpload(context.Background(), &s3.CreateMultipartUploadInput{Bucket: aws.String(bucket), Key: aws.String("k")})
	uploadId := aws.ToString(init.UploadId)

	p1, err := c.UploadPart(context.Background(), &s3.UploadPartInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String(uploadId),
		PartNumber: aws.Int32(1), Body: bytes.NewReader([]byte("tiny")),
	})
	if err != nil {
		t.Fatalf("UploadPart: %v", err)
	}
	out, err := c.CompleteMultipartUpload(context.Background(), &s3.CompleteMultipartUploadInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String(uploadId),
		MultipartUpload: &types.CompletedMultipartUpload{
			Parts: []types.CompletedPart{{ETag: p1.ETag, PartNumber: aws.Int32(1)}},
		},
	})
	if err != nil {
		t.Fatalf("Complete: %v", err)
	}
	if out.ETag == nil || !strings.Contains(*out.ETag, "-1\"") {
		t.Fatalf("expected -1 suffix, got %v", out.ETag)
	}
}

func TestMultipartUpload_PartNumber_OutOfRange(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "mpu-pn")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	init, _ := c.CreateMultipartUpload(context.Background(), &s3.CreateMultipartUploadInput{Bucket: aws.String(bucket), Key: aws.String("k")})
	uploadId := aws.ToString(init.UploadId)
	defer func() {
		_, _ = c.AbortMultipartUpload(context.Background(), &s3.AbortMultipartUploadInput{
			Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String(uploadId),
		})
	}()

	_, err := c.UploadPart(context.Background(), &s3.UploadPartInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String(uploadId),
		PartNumber: aws.Int32(0), Body: bytes.NewReader([]byte("x")),
	})
	if err == nil {
		t.Fatal("expected error for PartNumber=0")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 400 {
		t.Fatalf("expected 400, got %v", err)
	}

	_, err = c.UploadPart(context.Background(), &s3.UploadPartInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String(uploadId),
		PartNumber: aws.Int32(10001), Body: bytes.NewReader([]byte("x")),
	})
	if err == nil {
		t.Fatal("expected error for PartNumber=10001")
	}
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 400 {
		t.Fatalf("expected 400, got %v", err)
	}
}

func TestMultipartUpload_Abort(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "mpu-abort")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	init, _ := c.CreateMultipartUpload(context.Background(), &s3.CreateMultipartUploadInput{Bucket: aws.String(bucket), Key: aws.String("k")})
	uploadId := aws.ToString(init.UploadId)

	if _, err := c.AbortMultipartUpload(context.Background(), &s3.AbortMultipartUploadInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String(uploadId),
	}); err != nil {
		t.Fatalf("Abort: %v", err)
	}
	// After abort, UploadPart must fail with NoSuchUpload.
	_, err := c.UploadPart(context.Background(), &s3.UploadPartInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String(uploadId),
		PartNumber: aws.Int32(1), Body: bytes.NewReader([]byte("x")),
	})
	if err == nil {
		t.Fatal("expected NoSuchUpload, got nil")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 404 {
		t.Fatalf("expected 404, got %v", err)
	}
}

func TestMultipartUpload_ConditionalComplete_IfNoneMatchStar(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "mpu-cond")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	// Seed an existing object at "k".
	if _, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), Body: bytes.NewReader([]byte("orig")),
	}); err != nil {
		t.Fatalf("seed PUT: %v", err)
	}

	init, _ := c.CreateMultipartUpload(context.Background(), &s3.CreateMultipartUploadInput{Bucket: aws.String(bucket), Key: aws.String("k")})
	uploadId := aws.ToString(init.UploadId)
	p1, err := c.UploadPart(context.Background(), &s3.UploadPartInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String(uploadId),
		PartNumber: aws.Int32(1), Body: bytes.NewReader([]byte("new")),
	})
	if err != nil {
		t.Fatalf("UploadPart: %v", err)
	}

	_, err = c.CompleteMultipartUpload(context.Background(), &s3.CompleteMultipartUploadInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String(uploadId),
		IfNoneMatch: aws.String("*"),
		MultipartUpload: &types.CompletedMultipartUpload{
			Parts: []types.CompletedPart{{ETag: p1.ETag, PartNumber: aws.Int32(1)}},
		},
	})
	if err == nil {
		t.Fatal("expected 412 from If-None-Match=* on existing dest, got nil")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 412 {
		t.Fatalf("expected 412, got %v", err)
	}
}

func TestMultipartUpload_UploadPartCopy_Whole(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "mpu-upc")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("src")})
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("dst")})
		cleanupBucket(t, c, bucket)
	}()

	src := makePayload(minPartSize+100, 'C')
	if _, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("src"), Body: bytes.NewReader(src),
	}); err != nil {
		t.Fatalf("seed src: %v", err)
	}

	init, _ := c.CreateMultipartUpload(context.Background(), &s3.CreateMultipartUploadInput{Bucket: aws.String(bucket), Key: aws.String("dst")})
	uploadId := aws.ToString(init.UploadId)

	cp, err := c.UploadPartCopy(context.Background(), &s3.UploadPartCopyInput{
		Bucket:     aws.String(bucket),
		Key:        aws.String("dst"),
		UploadId:   aws.String(uploadId),
		PartNumber: aws.Int32(1),
		CopySource: aws.String(bucket + "/src"),
	})
	if err != nil {
		t.Fatalf("UploadPartCopy: %v", err)
	}
	if cp.CopyPartResult == nil || cp.CopyPartResult.ETag == nil {
		t.Fatal("missing CopyPartResult.ETag")
	}

	if _, err := c.CompleteMultipartUpload(context.Background(), &s3.CompleteMultipartUploadInput{
		Bucket: aws.String(bucket), Key: aws.String("dst"), UploadId: aws.String(uploadId),
		MultipartUpload: &types.CompletedMultipartUpload{
			Parts: []types.CompletedPart{{ETag: cp.CopyPartResult.ETag, PartNumber: aws.Int32(1)}},
		},
	}); err != nil {
		t.Fatalf("Complete: %v", err)
	}

	got, _ := c.GetObject(context.Background(), &s3.GetObjectInput{Bucket: aws.String(bucket), Key: aws.String("dst")})
	defer got.Body.Close()
	body, _ := io.ReadAll(got.Body)
	if !bytes.Equal(body, src) {
		t.Fatal("dst body != src body")
	}
}
