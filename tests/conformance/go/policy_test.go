package conformance

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	smithy "github.com/aws/smithy-go"
)

const samplePolicy = `{"Version":"2012-10-17","Statement":[{"Sid":"DenyAll","Effect":"Deny","Principal":"*","Action":"s3:*","Resource":"arn:aws:s3:::example/*"}]}`

func TestPolicy_RoundTrip(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "pol-rt")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.PutBucketPolicy(context.Background(), &s3.PutBucketPolicyInput{
		Bucket: aws.String(bucket),
		Policy: aws.String(samplePolicy),
	}); err != nil {
		t.Fatalf("PutBucketPolicy: %v", err)
	}
	out, err := c.GetBucketPolicy(context.Background(), &s3.GetBucketPolicyInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("GetBucketPolicy: %v", err)
	}
	if aws.ToString(out.Policy) != samplePolicy {
		t.Errorf("policy mismatch: got %q want %q", aws.ToString(out.Policy), samplePolicy)
	}
}

func TestPolicy_GetOnUntouched_404(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "pol-no")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	_, err := c.GetBucketPolicy(context.Background(), &s3.GetBucketPolicyInput{Bucket: aws.String(bucket)})
	if err == nil {
		t.Fatal("expected NoSuchBucketPolicy")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) || apiErr.ErrorCode() != "NoSuchBucketPolicy" {
		t.Fatalf("expected NoSuchBucketPolicy, got %v", err)
	}
}

func TestPolicy_Delete_Idempotent(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "pol-del")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	// Delete-before-Put is idempotent.
	if _, err := c.DeleteBucketPolicy(context.Background(), &s3.DeleteBucketPolicyInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("first delete: %v", err)
	}
	// Set, then delete twice.
	if _, err := c.PutBucketPolicy(context.Background(), &s3.PutBucketPolicyInput{Bucket: aws.String(bucket), Policy: aws.String(samplePolicy)}); err != nil {
		t.Fatalf("put: %v", err)
	}
	if _, err := c.DeleteBucketPolicy(context.Background(), &s3.DeleteBucketPolicyInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if _, err := c.DeleteBucketPolicy(context.Background(), &s3.DeleteBucketPolicyInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("redelete: %v", err)
	}
	_, err := c.GetBucketPolicy(context.Background(), &s3.GetBucketPolicyInput{Bucket: aws.String(bucket)})
	if err == nil {
		t.Fatal("expected NoSuchBucketPolicy after delete")
	}
}

func TestPolicy_Malformed_400(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "pol-bad")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	_, err := c.PutBucketPolicy(context.Background(), &s3.PutBucketPolicyInput{
		Bucket: aws.String(bucket),
		Policy: aws.String("not json"),
	})
	if err == nil {
		t.Fatal("expected MalformedPolicy")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) {
		t.Fatalf("not an API error: %v", err)
	}
	if !strings.Contains(apiErr.ErrorCode(), "MalformedPolicy") {
		t.Fatalf("expected MalformedPolicy, got %s: %v", apiErr.ErrorCode(), err)
	}
}
