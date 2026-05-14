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

func TestCors_RoundTrip(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cors-rt")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.PutBucketCors(context.Background(), &s3.PutBucketCorsInput{
		Bucket: aws.String(bucket),
		CORSConfiguration: &types.CORSConfiguration{
			CORSRules: []types.CORSRule{
				{
					AllowedMethods: []string{"GET", "PUT"},
					AllowedOrigins: []string{"https://example.com"},
					AllowedHeaders: []string{"*"},
					ExposeHeaders:  []string{"x-amz-version-id"},
					MaxAgeSeconds:  aws.Int32(3000),
				},
			},
		},
	}); err != nil {
		t.Fatalf("PutBucketCors: %v", err)
	}
	out, err := c.GetBucketCors(context.Background(), &s3.GetBucketCorsInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("GetBucketCors: %v", err)
	}
	if len(out.CORSRules) != 1 {
		t.Fatalf("expected 1 rule, got %d", len(out.CORSRules))
	}
	r := out.CORSRules[0]
	if len(r.AllowedMethods) != 2 || r.AllowedMethods[0] != "GET" {
		t.Errorf("methods mismatch: %v", r.AllowedMethods)
	}
	if aws.ToInt32(r.MaxAgeSeconds) != 3000 {
		t.Errorf("max-age mismatch: %d", aws.ToInt32(r.MaxAgeSeconds))
	}
}

func TestCors_GetOnUntouched_404(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cors-no")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	_, err := c.GetBucketCors(context.Background(), &s3.GetBucketCorsInput{Bucket: aws.String(bucket)})
	if err == nil {
		t.Fatal("expected NoSuchCORSConfiguration")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) || apiErr.ErrorCode() != "NoSuchCORSConfiguration" {
		t.Fatalf("expected NoSuchCORSConfiguration, got %v", err)
	}
}

func TestCors_Delete_Idempotent(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cors-del")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.DeleteBucketCors(context.Background(), &s3.DeleteBucketCorsInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("first delete: %v", err)
	}
	if _, err := c.PutBucketCors(context.Background(), &s3.PutBucketCorsInput{
		Bucket:            aws.String(bucket),
		CORSConfiguration: &types.CORSConfiguration{CORSRules: []types.CORSRule{{AllowedMethods: []string{"GET"}, AllowedOrigins: []string{"*"}}}},
	}); err != nil {
		t.Fatalf("put: %v", err)
	}
	if _, err := c.DeleteBucketCors(context.Background(), &s3.DeleteBucketCorsInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("delete: %v", err)
	}
}
