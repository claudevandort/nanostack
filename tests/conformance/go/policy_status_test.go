package conformance

import (
	"context"
	"errors"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	smithy "github.com/aws/smithy-go"
)

const publicPolicy = `{"Version":"2012-10-17","Statement":[{"Sid":"PubRead","Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::%s/*"}]}`
const privatePolicy = `{"Version":"2012-10-17","Statement":[{"Sid":"DenyAll","Effect":"Deny","Principal":"*","Action":"s3:*","Resource":"arn:aws:s3:::%s/*"}]}`

func TestPolicyStatus_GetOnUntouched_404(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ps-no")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	_, err := c.GetBucketPolicyStatus(context.Background(), &s3.GetBucketPolicyStatusInput{Bucket: aws.String(bucket)})
	if err == nil {
		t.Fatal("expected NoSuchBucketPolicy")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) || apiErr.ErrorCode() != "NoSuchBucketPolicy" {
		t.Fatalf("expected NoSuchBucketPolicy, got %v", err)
	}
}

func TestPolicyStatus_PublicAllow(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ps-pub")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)
	policy := aws.String(fmtPolicy(publicPolicy, bucket))
	if _, err := c.PutBucketPolicy(context.Background(), &s3.PutBucketPolicyInput{Bucket: aws.String(bucket), Policy: policy}); err != nil {
		t.Fatalf("PutBucketPolicy: %v", err)
	}
	out, err := c.GetBucketPolicyStatus(context.Background(), &s3.GetBucketPolicyStatusInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("GetBucketPolicyStatus: %v", err)
	}
	if !aws.ToBool(out.PolicyStatus.IsPublic) {
		t.Errorf("expected IsPublic=true with public-Allow policy")
	}
}

func TestPolicyStatus_DenyEffect_NotPublic(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ps-deny")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)
	policy := aws.String(fmtPolicy(privatePolicy, bucket))
	if _, err := c.PutBucketPolicy(context.Background(), &s3.PutBucketPolicyInput{Bucket: aws.String(bucket), Policy: policy}); err != nil {
		t.Fatalf("PutBucketPolicy: %v", err)
	}
	out, err := c.GetBucketPolicyStatus(context.Background(), &s3.GetBucketPolicyStatusInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("GetBucketPolicyStatus: %v", err)
	}
	if aws.ToBool(out.PolicyStatus.IsPublic) {
		t.Errorf("expected IsPublic=false with Deny-only policy")
	}
}

func fmtPolicy(template, bucket string) string {
	// Use a simple replace rather than fmt.Sprintf to avoid escaping `%`.
	out := make([]byte, 0, len(template)+len(bucket))
	for i := 0; i < len(template); i++ {
		if template[i] == '%' && i+1 < len(template) && template[i+1] == 's' {
			out = append(out, bucket...)
			i++
		} else {
			out = append(out, template[i])
		}
	}
	return string(out)
}
