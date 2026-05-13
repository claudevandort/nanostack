package conformance

import (
	"bytes"
	"context"
	"errors"
	"sort"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	smithy "github.com/aws/smithy-go"
)

func tagsToMap(tags []types.Tag) map[string]string {
	out := make(map[string]string, len(tags))
	for _, t := range tags {
		out[aws.ToString(t.Key)] = aws.ToString(t.Value)
	}
	return out
}

func TestTagging_BucketRoundTrip(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "tag-buk")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.PutBucketTagging(context.Background(), &s3.PutBucketTaggingInput{
		Bucket: aws.String(bucket),
		Tagging: &types.Tagging{
			TagSet: []types.Tag{
				{Key: aws.String("env"), Value: aws.String("prod")},
				{Key: aws.String("team"), Value: aws.String("alpha")},
			},
		},
	}); err != nil {
		t.Fatalf("PutBucketTagging: %v", err)
	}

	out, err := c.GetBucketTagging(context.Background(), &s3.GetBucketTaggingInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("GetBucketTagging: %v", err)
	}
	got := tagsToMap(out.TagSet)
	if got["env"] != "prod" || got["team"] != "alpha" {
		t.Errorf("tags mismatch: %v", got)
	}

	if _, err := c.DeleteBucketTagging(context.Background(), &s3.DeleteBucketTaggingInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("DeleteBucketTagging: %v", err)
	}
	_, err = c.GetBucketTagging(context.Background(), &s3.GetBucketTaggingInput{Bucket: aws.String(bucket)})
	if err == nil {
		t.Fatal("expected NoSuchTagSet after Delete")
	}
}

func TestTagging_BucketGetOnUntagged_NoSuchTagSet(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "tag-bk-no")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	_, err := c.GetBucketTagging(context.Background(), &s3.GetBucketTaggingInput{Bucket: aws.String(bucket)})
	if err == nil {
		t.Fatal("expected NoSuchTagSet, got nil")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) || apiErr.ErrorCode() != "NoSuchTagSet" {
		t.Fatalf("expected NoSuchTagSet, got %v", err)
	}
}

func TestTagging_ObjectRoundTrip(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "tag-obj")
	seedObject(t, c, bucket, "k", []byte("v"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	if _, err := c.PutObjectTagging(context.Background(), &s3.PutObjectTaggingInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("k"),
		Tagging: &types.Tagging{
			TagSet: []types.Tag{{Key: aws.String("env"), Value: aws.String("prod")}},
		},
	}); err != nil {
		t.Fatalf("PutObjectTagging: %v", err)
	}
	out, err := c.GetObjectTagging(context.Background(), &s3.GetObjectTaggingInput{
		Bucket: aws.String(bucket), Key: aws.String("k"),
	})
	if err != nil {
		t.Fatalf("GetObjectTagging: %v", err)
	}
	if got := tagsToMap(out.TagSet); got["env"] != "prod" {
		t.Errorf("tags mismatch: %v", got)
	}
}

func TestTagging_ObjectGetOnUntagged_EmptyTagSet(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "tag-obj-no")
	seedObject(t, c, bucket, "k", []byte("v"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	out, err := c.GetObjectTagging(context.Background(), &s3.GetObjectTaggingInput{
		Bucket: aws.String(bucket), Key: aws.String("k"),
	})
	if err != nil {
		t.Fatalf("GetObjectTagging on untagged: %v", err)
	}
	if len(out.TagSet) != 0 {
		t.Errorf("expected empty TagSet, got %v", out.TagSet)
	}
}

func TestTagging_PutObjectInlineHeader(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "tag-inline")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	if _, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket:  aws.String(bucket),
		Key:     aws.String("k"),
		Body:    bytes.NewReader([]byte("hi")),
		Tagging: aws.String("team=alpha&env=prod"),
	}); err != nil {
		t.Fatalf("Put with Tagging: %v", err)
	}
	out, err := c.GetObjectTagging(context.Background(), &s3.GetObjectTaggingInput{
		Bucket: aws.String(bucket), Key: aws.String("k"),
	})
	if err != nil {
		t.Fatalf("GetObjectTagging: %v", err)
	}
	got := tagsToMap(out.TagSet)
	if got["team"] != "alpha" || got["env"] != "prod" {
		t.Errorf("inline tags mismatch: %v", got)
	}
}

func TestTagging_CopyObject_DirectiveCopy_CarriesTags(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "tag-cp-c")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("src")})
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("dst")})
		cleanupBucket(t, c, bucket)
	}()

	if _, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("src"), Body: bytes.NewReader([]byte("v")),
		Tagging: aws.String("env=prod"),
	}); err != nil {
		t.Fatalf("seed src: %v", err)
	}

	if _, err := c.CopyObject(context.Background(), &s3.CopyObjectInput{
		Bucket:     aws.String(bucket),
		Key:        aws.String("dst"),
		CopySource: aws.String(bucket + "/src"),
		// TaggingDirective defaults to COPY.
	}); err != nil {
		t.Fatalf("CopyObject: %v", err)
	}
	out, _ := c.GetObjectTagging(context.Background(), &s3.GetObjectTaggingInput{
		Bucket: aws.String(bucket), Key: aws.String("dst"),
	})
	if tagsToMap(out.TagSet)["env"] != "prod" {
		t.Errorf("COPY directive didn't carry tags: %v", out.TagSet)
	}
}

func TestTagging_CopyObject_DirectiveReplace_OverridesTags(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "tag-cp-r")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("src")})
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("dst")})
		cleanupBucket(t, c, bucket)
	}()

	if _, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("src"), Body: bytes.NewReader([]byte("v")),
		Tagging: aws.String("env=prod&team=alpha"),
	}); err != nil {
		t.Fatalf("seed src: %v", err)
	}

	if _, err := c.CopyObject(context.Background(), &s3.CopyObjectInput{
		Bucket:            aws.String(bucket),
		Key:               aws.String("dst"),
		CopySource:        aws.String(bucket + "/src"),
		TaggingDirective:  types.TaggingDirectiveReplace,
		Tagging:           aws.String("phase=replace"),
	}); err != nil {
		t.Fatalf("CopyObject REPLACE: %v", err)
	}
	out, _ := c.GetObjectTagging(context.Background(), &s3.GetObjectTaggingInput{
		Bucket: aws.String(bucket), Key: aws.String("dst"),
	})
	got := tagsToMap(out.TagSet)
	if got["env"] != "" || got["team"] != "" {
		t.Errorf("REPLACE leaked source tags: %v", got)
	}
	if got["phase"] != "replace" {
		t.Errorf("REPLACE missing new tag: %v", got)
	}
}

func TestTagging_TooManyTags_InvalidTag(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "tag-many")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	tags := make([]types.Tag, 11)
	for i := range tags {
		k := byte('a' + i)
		tags[i] = types.Tag{Key: aws.String(string([]byte{k})), Value: aws.String("v")}
	}
	_, err := c.PutBucketTagging(context.Background(), &s3.PutBucketTaggingInput{
		Bucket:  aws.String(bucket),
		Tagging: &types.Tagging{TagSet: tags},
	})
	if err == nil {
		t.Fatal("expected InvalidTag (>10 tags)")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) || apiErr.ErrorCode() != "InvalidTag" {
		t.Fatalf("expected InvalidTag, got %v", err)
	}
}

func TestTagging_AwsPrefix_InvalidTag(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "tag-aws")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	_, err := c.PutBucketTagging(context.Background(), &s3.PutBucketTaggingInput{
		Bucket:  aws.String(bucket),
		Tagging: &types.Tagging{TagSet: []types.Tag{{Key: aws.String("aws:internal"), Value: aws.String("x")}}},
	})
	if err == nil {
		t.Fatal("expected InvalidTag for aws: prefix")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 400 {
		t.Fatalf("expected 400, got %v", err)
	}
}

func TestTagging_PerVersion(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "tag-ver")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if _, err := c.PutBucketVersioning(context.Background(), &s3.PutBucketVersioningInput{
		Bucket: aws.String(bucket),
		VersioningConfiguration: &types.VersioningConfiguration{Status: types.BucketVersioningStatusEnabled},
	}); err != nil {
		t.Fatalf("enable versioning: %v", err)
	}
	defer func() {
		drainVersions(t, c, bucket)
		cleanupBucket(t, c, bucket)
	}()

	v1, _ := c.PutObject(context.Background(), &s3.PutObjectInput{Bucket: aws.String(bucket), Key: aws.String("k"), Body: bytes.NewReader([]byte("first"))})
	v2, _ := c.PutObject(context.Background(), &s3.PutObjectInput{Bucket: aws.String(bucket), Key: aws.String("k"), Body: bytes.NewReader([]byte("second"))})

	// Tag only v1.
	if _, err := c.PutObjectTagging(context.Background(), &s3.PutObjectTaggingInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: v1.VersionId,
		Tagging: &types.Tagging{TagSet: []types.Tag{{Key: aws.String("rev"), Value: aws.String("1")}}},
	}); err != nil {
		t.Fatalf("Put tagging v1: %v", err)
	}

	// v1 has the tag; v2 does not.
	out1, _ := c.GetObjectTagging(context.Background(), &s3.GetObjectTaggingInput{Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: v1.VersionId})
	if tagsToMap(out1.TagSet)["rev"] != "1" {
		t.Errorf("v1 missing tag: %v", out1.TagSet)
	}
	out2, _ := c.GetObjectTagging(context.Background(), &s3.GetObjectTaggingInput{Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: v2.VersionId})
	if len(out2.TagSet) != 0 {
		t.Errorf("v2 should have no tags, got %v", out2.TagSet)
	}
}

func TestTagging_MultipartCreateWithTags(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "tag-mpu")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	init, _ := c.CreateMultipartUpload(context.Background(), &s3.CreateMultipartUploadInput{
		Bucket: aws.String(bucket), Key: aws.String("k"),
		Tagging: aws.String("env=prod"),
	})
	uploadId := aws.ToString(init.UploadId)
	payload := makePayload(minPartSize, 'A')
	p1, _ := c.UploadPart(context.Background(), &s3.UploadPartInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String(uploadId),
		PartNumber: aws.Int32(1), Body: bytes.NewReader(payload),
	})
	if _, err := c.CompleteMultipartUpload(context.Background(), &s3.CompleteMultipartUploadInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String(uploadId),
		MultipartUpload: &types.CompletedMultipartUpload{
			Parts: []types.CompletedPart{{ETag: p1.ETag, PartNumber: aws.Int32(1)}},
		},
	}); err != nil {
		t.Fatalf("Complete: %v", err)
	}
	out, _ := c.GetObjectTagging(context.Background(), &s3.GetObjectTaggingInput{Bucket: aws.String(bucket), Key: aws.String("k")})
	if tagsToMap(out.TagSet)["env"] != "prod" {
		t.Errorf("multipart didn't carry tags: %v", out.TagSet)
	}
}

// Keep `sort` referenced (used in versioning_test.go for the same package);
// avoids 'imported and not used' if this file is built alone.
var _ = sort.StringsAreSorted
