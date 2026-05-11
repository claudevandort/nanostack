package conformance

import (
	"context"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

func TestListBuckets_AfterCreate(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "lb")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed CreateBucket: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	out, err := c.ListBuckets(context.Background(), &s3.ListBucketsInput{})
	if err != nil {
		t.Fatalf("ListBuckets: %v", err)
	}

	// The bucket we just created must appear.
	var found bool
	for _, b := range out.Buckets {
		if b.Name != nil && *b.Name == bucket {
			found = true
			if b.CreationDate == nil {
				t.Errorf("bucket %q has nil CreationDate", bucket)
			}
			break
		}
	}
	if !found {
		t.Fatalf("ListBuckets did not include %q (got %d buckets)", bucket, len(out.Buckets))
	}

	// Owner block populated.
	if out.Owner == nil || out.Owner.ID == nil || *out.Owner.ID == "" {
		t.Fatalf("expected non-empty Owner.ID, got %+v", out.Owner)
	}
}
