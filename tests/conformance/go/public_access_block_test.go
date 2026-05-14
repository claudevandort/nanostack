package conformance

import (
	"context"
	"errors"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	smithy "github.com/aws/smithy-go"
)

func TestPublicAccessBlock_RoundTrip(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "pab-rt")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.PutPublicAccessBlock(context.Background(), &s3.PutPublicAccessBlockInput{
		Bucket: aws.String(bucket),
		PublicAccessBlockConfiguration: &types.PublicAccessBlockConfiguration{
			BlockPublicAcls:       aws.Bool(true),
			IgnorePublicAcls:      aws.Bool(true),
			BlockPublicPolicy:     aws.Bool(true),
			RestrictPublicBuckets: aws.Bool(true),
		},
	}); err != nil {
		t.Fatalf("PutPublicAccessBlock: %v", err)
	}
	out, err := c.GetPublicAccessBlock(context.Background(), &s3.GetPublicAccessBlockInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("GetPublicAccessBlock: %v", err)
	}
	cfg := out.PublicAccessBlockConfiguration
	if !aws.ToBool(cfg.BlockPublicAcls) || !aws.ToBool(cfg.RestrictPublicBuckets) {
		t.Errorf("PAB mismatch: %+v", cfg)
	}
}

func TestPublicAccessBlock_GetOnUntouched_404(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "pab-no")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	_, err := c.GetPublicAccessBlock(context.Background(), &s3.GetPublicAccessBlockInput{Bucket: aws.String(bucket)})
	if err == nil {
		t.Fatal("expected NoSuchPublicAccessBlockConfiguration")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) || apiErr.ErrorCode() != "NoSuchPublicAccessBlockConfiguration" {
		t.Fatalf("expected NoSuchPublicAccessBlockConfiguration, got %v", err)
	}
}

func TestPublicAccessBlock_Delete_Idempotent(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "pab-del")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.DeletePublicAccessBlock(context.Background(), &s3.DeletePublicAccessBlockInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("first delete: %v", err)
	}
	if _, err := c.PutPublicAccessBlock(context.Background(), &s3.PutPublicAccessBlockInput{
		Bucket: aws.String(bucket),
		PublicAccessBlockConfiguration: &types.PublicAccessBlockConfiguration{BlockPublicAcls: aws.Bool(true)},
	}); err != nil {
		t.Fatalf("put: %v", err)
	}
	if _, err := c.DeletePublicAccessBlock(context.Background(), &s3.DeletePublicAccessBlockInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("delete: %v", err)
	}
}
