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

func TestEncryption_AES256_RoundTrip(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "enc-aes")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.PutBucketEncryption(context.Background(), &s3.PutBucketEncryptionInput{
		Bucket: aws.String(bucket),
		ServerSideEncryptionConfiguration: &types.ServerSideEncryptionConfiguration{
			Rules: []types.ServerSideEncryptionRule{
				{ApplyServerSideEncryptionByDefault: &types.ServerSideEncryptionByDefault{SSEAlgorithm: types.ServerSideEncryptionAes256}},
			},
		},
	}); err != nil {
		t.Fatalf("Put: %v", err)
	}
	out, err := c.GetBucketEncryption(context.Background(), &s3.GetBucketEncryptionInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if out.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm != types.ServerSideEncryptionAes256 {
		t.Errorf("algorithm mismatch")
	}
}

func TestEncryption_KMS_RoundTrip(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "enc-kms")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	keyId := "arn:aws:kms:us-east-1:1234:key/abc-123"
	if _, err := c.PutBucketEncryption(context.Background(), &s3.PutBucketEncryptionInput{
		Bucket: aws.String(bucket),
		ServerSideEncryptionConfiguration: &types.ServerSideEncryptionConfiguration{
			Rules: []types.ServerSideEncryptionRule{
				{
					ApplyServerSideEncryptionByDefault: &types.ServerSideEncryptionByDefault{
						SSEAlgorithm:   types.ServerSideEncryptionAwsKms,
						KMSMasterKeyID: aws.String(keyId),
					},
					BucketKeyEnabled: aws.Bool(true),
				},
			},
		},
	}); err != nil {
		t.Fatalf("Put: %v", err)
	}
	out, err := c.GetBucketEncryption(context.Background(), &s3.GetBucketEncryptionInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	rule := out.ServerSideEncryptionConfiguration.Rules[0]
	if rule.ApplyServerSideEncryptionByDefault.SSEAlgorithm != types.ServerSideEncryptionAwsKms {
		t.Errorf("algorithm mismatch")
	}
	if aws.ToString(rule.ApplyServerSideEncryptionByDefault.KMSMasterKeyID) != keyId {
		t.Errorf("kms id mismatch")
	}
	if !aws.ToBool(rule.BucketKeyEnabled) {
		t.Errorf("bucket key enabled mismatch")
	}
}

func TestEncryption_GetOnUntouched_404(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "enc-no")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	_, err := c.GetBucketEncryption(context.Background(), &s3.GetBucketEncryptionInput{Bucket: aws.String(bucket)})
	if err == nil {
		t.Fatal("expected ServerSideEncryptionConfigurationNotFoundError")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) || apiErr.ErrorCode() != "ServerSideEncryptionConfigurationNotFoundError" {
		t.Fatalf("expected ServerSideEncryptionConfigurationNotFoundError, got %v", err)
	}
}

func TestEncryption_Delete_Idempotent(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "enc-del")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.DeleteBucketEncryption(context.Background(), &s3.DeleteBucketEncryptionInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("first delete: %v", err)
	}
}
