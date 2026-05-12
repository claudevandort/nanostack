package conformance

import (
	"bytes"
	"context"
	"sort"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

func seedBucketWithObjects(t *testing.T, c *s3.Client, bucket string, keys []string) {
	t.Helper()
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed CreateBucket: %v", err)
	}
	for _, k := range keys {
		if _, err := c.PutObject(context.Background(), &s3.PutObjectInput{
			Bucket: aws.String(bucket),
			Key:    aws.String(k),
			Body:   bytes.NewReader([]byte("v")),
		}); err != nil {
			t.Fatalf("seed Put %s: %v", k, err)
		}
	}
}

func TestListObjectsV2_EmptyBucket(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "lov2e")
	seedBucketWithObjects(t, c, bucket, nil)
	defer cleanupBucket(t, c, bucket)

	out, err := c.ListObjectsV2(context.Background(), &s3.ListObjectsV2Input{
		Bucket: aws.String(bucket),
	})
	if err != nil {
		t.Fatalf("ListObjectsV2: %v", err)
	}
	if out.KeyCount == nil || *out.KeyCount != 0 {
		t.Fatalf("KeyCount: got %v want 0", out.KeyCount)
	}
	if out.IsTruncated != nil && *out.IsTruncated {
		t.Fatalf("expected !IsTruncated")
	}
}

func TestListObjectsV2_AllKeys(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "lov2a")
	keys := []string{"alpha", "beta", "gamma", "delta", "epsilon"}
	seedBucketWithObjects(t, c, bucket, keys)
	defer func() {
		for _, k := range keys {
			_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String(k)})
		}
		cleanupBucket(t, c, bucket)
	}()

	out, err := c.ListObjectsV2(context.Background(), &s3.ListObjectsV2Input{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("ListObjectsV2: %v", err)
	}
	if len(out.Contents) != len(keys) {
		t.Fatalf("expected %d contents, got %d", len(keys), len(out.Contents))
	}
	gotKeys := make([]string, len(out.Contents))
	for i, c := range out.Contents {
		gotKeys[i] = aws.ToString(c.Key)
	}
	if !sort.StringsAreSorted(gotKeys) {
		t.Fatalf("response not sorted: %v", gotKeys)
	}
}

func TestListObjectsV2_Prefix(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "lov2p")
	keys := []string{"foo/a", "foo/b", "bar/c"}
	seedBucketWithObjects(t, c, bucket, keys)
	defer func() {
		for _, k := range keys {
			_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String(k)})
		}
		cleanupBucket(t, c, bucket)
	}()

	out, err := c.ListObjectsV2(context.Background(), &s3.ListObjectsV2Input{
		Bucket: aws.String(bucket),
		Prefix: aws.String("foo/"),
	})
	if err != nil {
		t.Fatalf("ListObjectsV2: %v", err)
	}
	if len(out.Contents) != 2 {
		t.Fatalf("expected 2 contents, got %d", len(out.Contents))
	}
	for _, obj := range out.Contents {
		if !strings.HasPrefix(aws.ToString(obj.Key), "foo/") {
			t.Errorf("unexpected key %q", aws.ToString(obj.Key))
		}
	}
}

func TestListObjectsV2_Delimiter(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "lov2d")
	keys := []string{"a/1", "a/2", "b/3", "c"}
	seedBucketWithObjects(t, c, bucket, keys)
	defer func() {
		for _, k := range keys {
			_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String(k)})
		}
		cleanupBucket(t, c, bucket)
	}()

	out, err := c.ListObjectsV2(context.Background(), &s3.ListObjectsV2Input{
		Bucket:    aws.String(bucket),
		Delimiter: aws.String("/"),
	})
	if err != nil {
		t.Fatalf("ListObjectsV2: %v", err)
	}
	// Expect Contents=[c], CommonPrefixes=[a/, b/]
	if len(out.Contents) != 1 {
		t.Errorf("expected 1 content, got %d", len(out.Contents))
	}
	if len(out.CommonPrefixes) != 2 {
		t.Fatalf("expected 2 common prefixes, got %d", len(out.CommonPrefixes))
	}
	cps := []string{
		aws.ToString(out.CommonPrefixes[0].Prefix),
		aws.ToString(out.CommonPrefixes[1].Prefix),
	}
	sort.Strings(cps)
	if cps[0] != "a/" || cps[1] != "b/" {
		t.Fatalf("unexpected CommonPrefixes: %v", cps)
	}
}

func TestListObjectsV2_Pagination(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "lov2page")
	keys := []string{"k1", "k2", "k3", "k4", "k5"}
	seedBucketWithObjects(t, c, bucket, keys)
	defer func() {
		for _, k := range keys {
			_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String(k)})
		}
		cleanupBucket(t, c, bucket)
	}()

	var seen []string
	var token *string
	pages := 0
	for {
		pages++
		out, err := c.ListObjectsV2(context.Background(), &s3.ListObjectsV2Input{
			Bucket:            aws.String(bucket),
			MaxKeys:           aws.Int32(2),
			ContinuationToken: token,
		})
		if err != nil {
			t.Fatalf("ListObjectsV2 page %d: %v", pages, err)
		}
		for _, obj := range out.Contents {
			seen = append(seen, aws.ToString(obj.Key))
		}
		if out.IsTruncated == nil || !*out.IsTruncated {
			break
		}
		token = out.NextContinuationToken
		if pages > 10 {
			t.Fatal("too many pages")
		}
	}
	if pages != 3 {
		t.Errorf("expected 3 pages (2+2+1), got %d", pages)
	}
	sort.Strings(seen)
	for i, k := range keys {
		if seen[i] != k {
			t.Errorf("page set mismatch at %d: got %q want %q", i, seen[i], k)
		}
	}
}

func TestListObjectsV2_StartAfter(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "lov2sa")
	keys := []string{"a", "b", "c", "d"}
	seedBucketWithObjects(t, c, bucket, keys)
	defer func() {
		for _, k := range keys {
			_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String(k)})
		}
		cleanupBucket(t, c, bucket)
	}()

	out, err := c.ListObjectsV2(context.Background(), &s3.ListObjectsV2Input{
		Bucket:     aws.String(bucket),
		StartAfter: aws.String("b"),
	})
	if err != nil {
		t.Fatalf("ListObjectsV2: %v", err)
	}
	if len(out.Contents) != 2 {
		t.Fatalf("expected 2 contents after 'b', got %d", len(out.Contents))
	}
	if aws.ToString(out.Contents[0].Key) != "c" || aws.ToString(out.Contents[1].Key) != "d" {
		t.Fatalf("got %v", out.Contents)
	}
}

func TestListObjects_V1_Marker(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "lov1m")
	keys := []string{"a", "b", "c", "d"}
	seedBucketWithObjects(t, c, bucket, keys)
	defer func() {
		for _, k := range keys {
			_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String(k)})
		}
		cleanupBucket(t, c, bucket)
	}()

	out, err := c.ListObjects(context.Background(), &s3.ListObjectsInput{
		Bucket: aws.String(bucket),
		Marker: aws.String("b"),
	})
	if err != nil {
		t.Fatalf("ListObjects v1: %v", err)
	}
	if len(out.Contents) != 2 {
		t.Fatalf("expected 2 contents after marker 'b', got %d", len(out.Contents))
	}
	if aws.ToString(out.Contents[0].Key) != "c" || aws.ToString(out.Contents[1].Key) != "d" {
		t.Fatalf("got %v", out.Contents)
	}
}
