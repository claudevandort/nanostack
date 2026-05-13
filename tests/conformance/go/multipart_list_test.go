package conformance

import (
	"bytes"
	"context"
	"sort"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

func TestMultipart_ListMultipartUploads_Basic(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "lmu-basic")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	keys := []string{"alpha", "beta", "gamma"}
	uploadIds := make([]string, 0, len(keys))
	defer func() {
		for i, k := range keys {
			_, _ = c.AbortMultipartUpload(context.Background(), &s3.AbortMultipartUploadInput{
				Bucket: aws.String(bucket), Key: aws.String(k), UploadId: aws.String(uploadIds[i]),
			})
		}
	}()
	for _, k := range keys {
		init, err := c.CreateMultipartUpload(context.Background(), &s3.CreateMultipartUploadInput{Bucket: aws.String(bucket), Key: aws.String(k)})
		if err != nil {
			t.Fatalf("init %s: %v", k, err)
		}
		uploadIds = append(uploadIds, aws.ToString(init.UploadId))
	}

	out, err := c.ListMultipartUploads(context.Background(), &s3.ListMultipartUploadsInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("ListMultipartUploads: %v", err)
	}
	if len(out.Uploads) != 3 {
		t.Fatalf("expected 3 uploads, got %d", len(out.Uploads))
	}
	gotKeys := make([]string, len(out.Uploads))
	for i, u := range out.Uploads {
		gotKeys[i] = aws.ToString(u.Key)
	}
	if !sort.StringsAreSorted(gotKeys) {
		t.Errorf("uploads not sorted by key: %v", gotKeys)
	}
}

func TestMultipart_ListMultipartUploads_Pagination(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "lmu-page")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	keys := []string{"k1", "k2", "k3", "k4", "k5"}
	uploadIds := make([]string, 0, len(keys))
	defer func() {
		for i, k := range keys {
			_, _ = c.AbortMultipartUpload(context.Background(), &s3.AbortMultipartUploadInput{
				Bucket: aws.String(bucket), Key: aws.String(k), UploadId: aws.String(uploadIds[i]),
			})
		}
	}()
	for _, k := range keys {
		init, _ := c.CreateMultipartUpload(context.Background(), &s3.CreateMultipartUploadInput{Bucket: aws.String(bucket), Key: aws.String(k)})
		uploadIds = append(uploadIds, aws.ToString(init.UploadId))
	}

	var seen []string
	var keyMarker, idMarker *string
	pages := 0
	for {
		pages++
		out, err := c.ListMultipartUploads(context.Background(), &s3.ListMultipartUploadsInput{
			Bucket:         aws.String(bucket),
			MaxUploads:     aws.Int32(2),
			KeyMarker:      keyMarker,
			UploadIdMarker: idMarker,
		})
		if err != nil {
			t.Fatalf("LMU page %d: %v", pages, err)
		}
		for _, u := range out.Uploads {
			seen = append(seen, aws.ToString(u.Key))
		}
		if out.IsTruncated == nil || !*out.IsTruncated {
			break
		}
		keyMarker = out.NextKeyMarker
		idMarker = out.NextUploadIdMarker
		if pages > 10 {
			t.Fatal("too many pages")
		}
	}
	if pages != 3 {
		t.Errorf("expected 3 pages, got %d", pages)
	}
	sort.Strings(seen)
	for i, k := range keys {
		if seen[i] != k {
			t.Errorf("page mismatch at %d: got %q want %q", i, seen[i], k)
		}
	}
}

func TestMultipart_ListParts_Pagination(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "lp-page")
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

	for i := int32(1); i <= 5; i++ {
		_, err := c.UploadPart(context.Background(), &s3.UploadPartInput{
			Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String(uploadId),
			PartNumber: aws.Int32(i), Body: bytes.NewReader([]byte("x")),
		})
		if err != nil {
			t.Fatalf("UploadPart %d: %v", i, err)
		}
	}

	var seen []int32
	var marker *string
	pages := 0
	for {
		pages++
		out, err := c.ListParts(context.Background(), &s3.ListPartsInput{
			Bucket: aws.String(bucket), Key: aws.String("k"), UploadId: aws.String(uploadId),
			MaxParts:         aws.Int32(2),
			PartNumberMarker: marker,
		})
		if err != nil {
			t.Fatalf("ListParts page %d: %v", pages, err)
		}
		for _, p := range out.Parts {
			seen = append(seen, aws.ToInt32(p.PartNumber))
		}
		if out.IsTruncated == nil || !*out.IsTruncated {
			break
		}
		marker = out.NextPartNumberMarker
		if pages > 10 {
			t.Fatal("too many pages")
		}
	}
	if pages != 3 {
		t.Errorf("expected 3 pages, got %d", pages)
	}
	if len(seen) != 5 {
		t.Errorf("expected 5 parts total, got %d", len(seen))
	}
}
