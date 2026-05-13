package conformance

import (
	"bytes"
	"context"
	"errors"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	smithy "github.com/aws/smithy-go"
)

func TestMultipart_EntityTooSmall_NonFinalUndersized(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "mp-ets")
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

	// Two small parts → first part is non-final and < 5 MiB → EntityTooSmall.
	p1, _ := c.UploadPart(context.Background(), &s3.UploadPartInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String(uploadId),
		PartNumber: aws.Int32(1), Body: bytes.NewReader([]byte("small1")),
	})
	p2, _ := c.UploadPart(context.Background(), &s3.UploadPartInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String(uploadId),
		PartNumber: aws.Int32(2), Body: bytes.NewReader([]byte("small2")),
	})

	_, err := c.CompleteMultipartUpload(context.Background(), &s3.CompleteMultipartUploadInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String(uploadId),
		MultipartUpload: &types.CompletedMultipartUpload{
			Parts: []types.CompletedPart{
				{ETag: p1.ETag, PartNumber: aws.Int32(1)},
				{ETag: p2.ETag, PartNumber: aws.Int32(2)},
			},
		},
	})
	if err == nil {
		t.Fatal("expected EntityTooSmall, got nil")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) || apiErr.ErrorCode() != "EntityTooSmall" {
		t.Fatalf("expected EntityTooSmall, got %v", err)
	}
}

func TestMultipart_FinalPart_AnySize_OK(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "mp-final")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	init, _ := c.CreateMultipartUpload(context.Background(), &s3.CreateMultipartUploadInput{Bucket: aws.String(bucket), Key: aws.String("k")})
	uploadId := aws.ToString(init.UploadId)

	big := makePayload(minPartSize, 'A')
	tail := []byte("tail")

	p1, _ := c.UploadPart(context.Background(), &s3.UploadPartInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String(uploadId),
		PartNumber: aws.Int32(1), Body: bytes.NewReader(big),
	})
	p2, _ := c.UploadPart(context.Background(), &s3.UploadPartInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String(uploadId),
		PartNumber: aws.Int32(2), Body: bytes.NewReader(tail),
	})

	if _, err := c.CompleteMultipartUpload(context.Background(), &s3.CompleteMultipartUploadInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String(uploadId),
		MultipartUpload: &types.CompletedMultipartUpload{
			Parts: []types.CompletedPart{
				{ETag: p1.ETag, PartNumber: aws.Int32(1)},
				{ETag: p2.ETag, PartNumber: aws.Int32(2)},
			},
		},
	}); err != nil {
		t.Fatalf("expected success (final part can be < 5 MiB), got %v", err)
	}
}

func TestMultipart_NoSuchUpload(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "mp-nsu")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	_, err := c.UploadPart(context.Background(), &s3.UploadPartInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String("ghost-upload-id"),
		PartNumber: aws.Int32(1), Body: bytes.NewReader([]byte("x")),
	})
	if err == nil {
		t.Fatal("expected NoSuchUpload")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 404 {
		t.Fatalf("expected 404, got %v", err)
	}
}

func TestMultipart_InvalidPart_UnknownNumber(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "mp-invp")
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

	// Claim a part number that was never uploaded.
	_, err := c.CompleteMultipartUpload(context.Background(), &s3.CompleteMultipartUploadInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String(uploadId),
		MultipartUpload: &types.CompletedMultipartUpload{
			Parts: []types.CompletedPart{{ETag: aws.String("\"deadbeef\""), PartNumber: aws.Int32(1)}},
		},
	})
	if err == nil {
		t.Fatal("expected InvalidPart, got nil")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) || apiErr.ErrorCode() != "InvalidPart" {
		t.Fatalf("expected InvalidPart, got %v", err)
	}
}
