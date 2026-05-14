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

func TestOwnership_RoundTrip(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "own-rt")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.PutBucketOwnershipControls(context.Background(), &s3.PutBucketOwnershipControlsInput{
		Bucket: aws.String(bucket),
		OwnershipControls: &types.OwnershipControls{
			Rules: []types.OwnershipControlsRule{{ObjectOwnership: types.ObjectOwnershipBucketOwnerEnforced}},
		},
	}); err != nil {
		t.Fatalf("PutBucketOwnershipControls: %v", err)
	}
	out, err := c.GetBucketOwnershipControls(context.Background(), &s3.GetBucketOwnershipControlsInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("GetBucketOwnershipControls: %v", err)
	}
	if len(out.OwnershipControls.Rules) != 1 || out.OwnershipControls.Rules[0].ObjectOwnership != types.ObjectOwnershipBucketOwnerEnforced {
		t.Errorf("ownership mismatch: %+v", out.OwnershipControls)
	}
}

func TestOwnership_GetOnUntouched_404(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "own-no")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	_, err := c.GetBucketOwnershipControls(context.Background(), &s3.GetBucketOwnershipControlsInput{Bucket: aws.String(bucket)})
	if err == nil {
		t.Fatal("expected OwnershipControlsNotFoundError")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) || apiErr.ErrorCode() != "OwnershipControlsNotFoundError" {
		t.Fatalf("expected OwnershipControlsNotFoundError, got %v", err)
	}
}

func TestOwnership_Delete_Idempotent(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "own-del")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.DeleteBucketOwnershipControls(context.Background(), &s3.DeleteBucketOwnershipControlsInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("first delete: %v", err)
	}
	if _, err := c.PutBucketOwnershipControls(context.Background(), &s3.PutBucketOwnershipControlsInput{
		Bucket: aws.String(bucket),
		OwnershipControls: &types.OwnershipControls{
			Rules: []types.OwnershipControlsRule{{ObjectOwnership: types.ObjectOwnershipObjectWriter}},
		},
	}); err != nil {
		t.Fatalf("put: %v", err)
	}
	if _, err := c.DeleteBucketOwnershipControls(context.Background(), &s3.DeleteBucketOwnershipControlsInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("delete: %v", err)
	}
}
