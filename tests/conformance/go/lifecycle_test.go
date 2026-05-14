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

func TestLifecycle_SingleRule_Expiration(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "lc-rt")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.PutBucketLifecycleConfiguration(context.Background(), &s3.PutBucketLifecycleConfigurationInput{
		Bucket: aws.String(bucket),
		LifecycleConfiguration: &types.BucketLifecycleConfiguration{
			Rules: []types.LifecycleRule{
				{
					ID:         aws.String("r1"),
					Status:     types.ExpirationStatusEnabled,
					Filter:     &types.LifecycleRuleFilterMemberPrefix{Value: "tmp/"},
					Expiration: &types.LifecycleExpiration{Days: aws.Int32(7)},
				},
			},
		},
	}); err != nil {
		t.Fatalf("Put: %v", err)
	}
	out, err := c.GetBucketLifecycleConfiguration(context.Background(), &s3.GetBucketLifecycleConfigurationInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if aws.ToString(out.Rules[0].ID) != "r1" {
		t.Errorf("id mismatch")
	}
	if aws.ToInt32(out.Rules[0].Expiration.Days) != 7 {
		t.Errorf("expiration days mismatch")
	}
}

func TestLifecycle_TransitionAndNoncurrent(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "lc-tr")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.PutBucketLifecycleConfiguration(context.Background(), &s3.PutBucketLifecycleConfigurationInput{
		Bucket: aws.String(bucket),
		LifecycleConfiguration: &types.BucketLifecycleConfiguration{
			Rules: []types.LifecycleRule{
				{
					Status: types.ExpirationStatusEnabled,
					Filter: &types.LifecycleRuleFilterMemberPrefix{Value: ""},
					Transitions: []types.Transition{
						{Days: aws.Int32(30), StorageClass: types.TransitionStorageClassGlacier},
					},
					NoncurrentVersionExpiration: &types.NoncurrentVersionExpiration{NoncurrentDays: aws.Int32(90)},
				},
			},
		},
	}); err != nil {
		t.Fatalf("Put: %v", err)
	}
	out, err := c.GetBucketLifecycleConfiguration(context.Background(), &s3.GetBucketLifecycleConfigurationInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if out.Rules[0].Transitions[0].StorageClass != types.TransitionStorageClassGlacier {
		t.Errorf("transition storage class mismatch")
	}
	if aws.ToInt32(out.Rules[0].NoncurrentVersionExpiration.NoncurrentDays) != 90 {
		t.Errorf("noncurrent days mismatch")
	}
}

func TestLifecycle_GetOnUntouched_404(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "lc-no")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	_, err := c.GetBucketLifecycleConfiguration(context.Background(), &s3.GetBucketLifecycleConfigurationInput{Bucket: aws.String(bucket)})
	if err == nil {
		t.Fatal("expected NoSuchLifecycleConfiguration")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) || apiErr.ErrorCode() != "NoSuchLifecycleConfiguration" {
		t.Fatalf("expected NoSuchLifecycleConfiguration, got %v", err)
	}
}

func TestLifecycle_Delete_Idempotent(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "lc-del")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.DeleteBucketLifecycle(context.Background(), &s3.DeleteBucketLifecycleInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("first delete: %v", err)
	}
}
