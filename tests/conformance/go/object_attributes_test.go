package conformance

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	smithy "github.com/aws/smithy-go"
)

func TestObjectAttributes_Single(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "attr-1")
	seedObject(t, c, bucket, "k", []byte("hello"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	out, err := c.GetObjectAttributes(context.Background(), &s3.GetObjectAttributesInput{
		Bucket:           aws.String(bucket),
		Key:              aws.String("k"),
		ObjectAttributes: []types.ObjectAttributes{types.ObjectAttributesEtag},
	})
	if err != nil {
		t.Fatalf("GetObjectAttributes: %v", err)
	}
	if aws.ToString(out.ETag) == "" {
		t.Errorf("expected non-empty ETag")
	}
}

func TestObjectAttributes_ObjectSize(t *testing.T) {
	// NOTE: The Go SDK sends one `X-Amz-Object-Attributes` HTTP header per
	// requested attribute. Our SigV4 canonical-headers handling currently
	// only sees the first occurrence (pre-existing limitation documented
	// in SUPPORT.md). So we exercise one attribute per call here.
	c := newClient(t)
	bucket := uniqueBucketName(t, "attr-sz")
	seedObject(t, c, bucket, "k", []byte("hello world"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	out, err := c.GetObjectAttributes(context.Background(), &s3.GetObjectAttributesInput{
		Bucket:           aws.String(bucket),
		Key:              aws.String("k"),
		ObjectAttributes: []types.ObjectAttributes{types.ObjectAttributesObjectSize},
	})
	if err != nil {
		t.Fatalf("GetObjectAttributes: %v", err)
	}
	if aws.ToInt64(out.ObjectSize) != 11 {
		t.Errorf("expected size 11, got %d", aws.ToInt64(out.ObjectSize))
	}
}

func TestObjectAttributes_StorageClass(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "attr-sc")
	seedObject(t, c, bucket, "k", []byte("x"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	out, err := c.GetObjectAttributes(context.Background(), &s3.GetObjectAttributesInput{
		Bucket:           aws.String(bucket),
		Key:              aws.String("k"),
		ObjectAttributes: []types.ObjectAttributes{types.ObjectAttributesStorageClass},
	})
	if err != nil {
		t.Fatalf("GetObjectAttributes: %v", err)
	}
	if out.StorageClass != types.StorageClassStandard {
		t.Errorf("expected STANDARD storage class, got %v", out.StorageClass)
	}
}

func TestObjectAttributes_NoSuchKey(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "attr-nk")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	_, err := c.GetObjectAttributes(context.Background(), &s3.GetObjectAttributesInput{
		Bucket:           aws.String(bucket),
		Key:              aws.String("missing"),
		ObjectAttributes: []types.ObjectAttributes{types.ObjectAttributesEtag},
	})
	if err == nil {
		t.Fatal("expected NoSuchKey")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) || apiErr.ErrorCode() != "NoSuchKey" {
		t.Fatalf("expected NoSuchKey, got %v", err)
	}
}

func TestObjectAttributes_MultipartObjectParts(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "attr-mpu")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	init, _ := c.CreateMultipartUpload(context.Background(), &s3.CreateMultipartUploadInput{Bucket: aws.String(bucket), Key: aws.String("k")})
	uploadId := aws.ToString(init.UploadId)
	payload := makePayload(minPartSize, 'A')
	p1, _ := c.UploadPart(context.Background(), &s3.UploadPartInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String(uploadId),
		PartNumber: aws.Int32(1), Body: bytes.NewReader(payload),
	})
	if _, err := c.CompleteMultipartUpload(context.Background(), &s3.CompleteMultipartUploadInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String(uploadId),
		MultipartUpload: &types.CompletedMultipartUpload{Parts: []types.CompletedPart{{ETag: p1.ETag, PartNumber: aws.Int32(1)}}},
	}); err != nil {
		t.Fatalf("Complete: %v", err)
	}

	out, err := c.GetObjectAttributes(context.Background(), &s3.GetObjectAttributesInput{
		Bucket: aws.String(bucket), Key: aws.String("k"),
		ObjectAttributes: []types.ObjectAttributes{types.ObjectAttributesObjectParts},
	})
	if err != nil {
		t.Fatalf("GetObjectAttributes: %v", err)
	}
	if out.ObjectParts == nil || aws.ToInt32(out.ObjectParts.TotalPartsCount) != 1 {
		t.Errorf("expected ObjectParts.TotalPartsCount=1, got %+v", out.ObjectParts)
	}

	// ETag with -1 suffix is verifiable independently via HeadObject.
	head, _ := c.HeadObject(context.Background(), &s3.HeadObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
	if !strings.HasSuffix(aws.ToString(head.ETag), "-1\"") {
		t.Errorf("expected multipart ETag with -1 suffix, got %s", aws.ToString(head.ETag))
	}
}

func TestObjectAttributes_PerVersion(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "attr-ver")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if _, err := c.PutBucketVersioning(context.Background(), &s3.PutBucketVersioningInput{
		Bucket: aws.String(bucket),
		VersioningConfiguration: &types.VersioningConfiguration{Status: types.BucketVersioningStatusEnabled},
	}); err != nil {
		t.Fatalf("versioning: %v", err)
	}
	defer func() {
		drainVersions(t, c, bucket)
		cleanupBucket(t, c, bucket)
	}()

	v1, _ := c.PutObject(context.Background(), &s3.PutObjectInput{Bucket: aws.String(bucket), Key: aws.String("k"), Body: bytes.NewReader([]byte("first"))})
	v2, _ := c.PutObject(context.Background(), &s3.PutObjectInput{Bucket: aws.String(bucket), Key: aws.String("k"), Body: bytes.NewReader([]byte("second-longer"))})

	out1, _ := c.GetObjectAttributes(context.Background(), &s3.GetObjectAttributesInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: v1.VersionId,
		ObjectAttributes: []types.ObjectAttributes{types.ObjectAttributesObjectSize},
	})
	out2, _ := c.GetObjectAttributes(context.Background(), &s3.GetObjectAttributesInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: v2.VersionId,
		ObjectAttributes: []types.ObjectAttributes{types.ObjectAttributesObjectSize},
	})
	if aws.ToInt64(out1.ObjectSize) != 5 || aws.ToInt64(out2.ObjectSize) != 13 {
		t.Errorf("per-version sizes wrong: v1=%d v2=%d", aws.ToInt64(out1.ObjectSize), aws.ToInt64(out2.ObjectSize))
	}
}
