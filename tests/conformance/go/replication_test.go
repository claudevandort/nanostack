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

func TestReplication_RoundTrip(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "repl-rt")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)
	// Replication requires versioning enabled on source.
	if _, err := c.PutBucketVersioning(context.Background(), &s3.PutBucketVersioningInput{
		Bucket:                  aws.String(bucket),
		VersioningConfiguration: &types.VersioningConfiguration{Status: types.BucketVersioningStatusEnabled},
	}); err != nil {
		t.Fatalf("versioning: %v", err)
	}

	if _, err := c.PutBucketReplication(context.Background(), &s3.PutBucketReplicationInput{
		Bucket: aws.String(bucket),
		ReplicationConfiguration: &types.ReplicationConfiguration{
			Role: aws.String("arn:aws:iam::1:role/repl"),
			Rules: []types.ReplicationRule{
				{
					ID:     aws.String("r1"),
					Status: types.ReplicationRuleStatusEnabled,
					Prefix: aws.String("logs/"),
					Destination: &types.Destination{
						Bucket: aws.String("arn:aws:s3:::dest"),
					},
				},
			},
		},
	}); err != nil {
		t.Fatalf("Put: %v", err)
	}
	out, err := c.GetBucketReplication(context.Background(), &s3.GetBucketReplicationInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if aws.ToString(out.ReplicationConfiguration.Role) != "arn:aws:iam::1:role/repl" {
		t.Errorf("role mismatch")
	}
	if len(out.ReplicationConfiguration.Rules) != 1 || aws.ToString(out.ReplicationConfiguration.Rules[0].ID) != "r1" {
		t.Errorf("rule id mismatch")
	}
}

func TestReplication_GetOnUntouched_404(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "repl-no")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	_, err := c.GetBucketReplication(context.Background(), &s3.GetBucketReplicationInput{Bucket: aws.String(bucket)})
	if err == nil {
		t.Fatal("expected ReplicationConfigurationNotFoundError")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) || apiErr.ErrorCode() != "ReplicationConfigurationNotFoundError" {
		t.Fatalf("expected ReplicationConfigurationNotFoundError, got %v", err)
	}
}

func TestReplication_Delete_Idempotent(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "repl-del")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.DeleteBucketReplication(context.Background(), &s3.DeleteBucketReplicationInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("first delete: %v", err)
	}
}
