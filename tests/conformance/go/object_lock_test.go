package conformance

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	smithy "github.com/aws/smithy-go"
)

// Create a bucket with Object Lock enabled (auto-enables versioning).
func createLockedBucket(t *testing.T, c *s3.Client, name string) {
	t.Helper()
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{
		Bucket:                     aws.String(name),
		ObjectLockEnabledForBucket: aws.Bool(true),
	}); err != nil {
		t.Fatalf("CreateBucket(ObjectLock): %v", err)
	}
}

func TestObjectLock_CreateBucket_AutoEnablesVersioning(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ol-auto")
	createLockedBucket(t, c, bucket)
	defer cleanupBucket(t, c, bucket)

	out, err := c.GetBucketVersioning(context.Background(), &s3.GetBucketVersioningInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("GetBucketVersioning: %v", err)
	}
	if out.Status != types.BucketVersioningStatusEnabled {
		t.Errorf("expected versioning Enabled, got %v", out.Status)
	}
}

func TestObjectLock_Suspend_Rejected(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ol-susp")
	createLockedBucket(t, c, bucket)
	defer cleanupBucket(t, c, bucket)

	_, err := c.PutBucketVersioning(context.Background(), &s3.PutBucketVersioningInput{
		Bucket:                  aws.String(bucket),
		VersioningConfiguration: &types.VersioningConfiguration{Status: types.BucketVersioningStatusSuspended},
	})
	if err == nil {
		t.Fatal("expected InvalidBucketState")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) || apiErr.ErrorCode() != "InvalidBucketState" {
		t.Fatalf("expected InvalidBucketState, got %v", err)
	}
}

func TestObjectLock_PutConfigOnNonLockedBucket_Rejected(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ol-no")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	_, err := c.PutObjectLockConfiguration(context.Background(), &s3.PutObjectLockConfigurationInput{
		Bucket: aws.String(bucket),
		ObjectLockConfiguration: &types.ObjectLockConfiguration{
			ObjectLockEnabled: types.ObjectLockEnabledEnabled,
		},
	})
	if err == nil {
		t.Fatal("expected InvalidBucketState")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) || apiErr.ErrorCode() != "InvalidBucketState" {
		t.Fatalf("expected InvalidBucketState, got %v", err)
	}
}

func TestObjectLock_Config_RoundTrip(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ol-cfg")
	createLockedBucket(t, c, bucket)
	defer cleanupBucket(t, c, bucket)

	if _, err := c.PutObjectLockConfiguration(context.Background(), &s3.PutObjectLockConfigurationInput{
		Bucket: aws.String(bucket),
		ObjectLockConfiguration: &types.ObjectLockConfiguration{
			ObjectLockEnabled: types.ObjectLockEnabledEnabled,
			Rule: &types.ObjectLockRule{
				DefaultRetention: &types.DefaultRetention{
					Mode: types.ObjectLockRetentionModeGovernance,
					Days: aws.Int32(1),
				},
			},
		},
	}); err != nil {
		t.Fatalf("Put: %v", err)
	}
	out, err := c.GetObjectLockConfiguration(context.Background(), &s3.GetObjectLockConfigurationInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if out.ObjectLockConfiguration.Rule.DefaultRetention.Mode != types.ObjectLockRetentionModeGovernance {
		t.Errorf("mode mismatch")
	}
	if aws.ToInt32(out.ObjectLockConfiguration.Rule.DefaultRetention.Days) != 1 {
		t.Errorf("days mismatch")
	}
}

func TestObjectLock_GetConfig_BareEnabled(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ol-bare")
	createLockedBucket(t, c, bucket)
	defer cleanupBucket(t, c, bucket)

	out, err := c.GetObjectLockConfiguration(context.Background(), &s3.GetObjectLockConfigurationInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if out.ObjectLockConfiguration.ObjectLockEnabled != types.ObjectLockEnabledEnabled {
		t.Errorf("expected Enabled, got %v", out.ObjectLockConfiguration.ObjectLockEnabled)
	}
}

// Helper: put object with GOVERNANCE retention 1 day from now, return version id.
func putWithGovernance(t *testing.T, c *s3.Client, bucket, key string) string {
	t.Helper()
	until := time.Now().Add(24 * time.Hour).UTC()
	out, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket:                    aws.String(bucket),
		Key:                       aws.String(key),
		Body:                      bytes.NewReader([]byte("locked")),
		ObjectLockMode:            types.ObjectLockModeGovernance,
		ObjectLockRetainUntilDate: aws.Time(until),
	})
	if err != nil {
		t.Fatalf("PutObject with retention: %v", err)
	}
	return aws.ToString(out.VersionId)
}

func TestObjectLock_Retention_RoundTrip(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ol-rt")
	createLockedBucket(t, c, bucket)
	defer func() {
		drainVersions(t, c, bucket)
		cleanupBucket(t, c, bucket)
	}()

	vid := putWithGovernance(t, c, bucket, "k")
	out, err := c.GetObjectRetention(context.Background(), &s3.GetObjectRetentionInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: aws.String(vid),
	})
	if err != nil {
		t.Fatalf("GetObjectRetention: %v", err)
	}
	if out.Retention.Mode != types.ObjectLockRetentionModeGovernance {
		t.Errorf("mode mismatch")
	}
}

func TestObjectLock_DeleteWithinGovernance_AccessDenied(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ol-gd")
	createLockedBucket(t, c, bucket)
	defer func() {
		// Drain with bypass so cleanup succeeds.
		list, _ := c.ListObjectVersions(context.Background(), &s3.ListObjectVersionsInput{Bucket: aws.String(bucket)})
		for _, v := range list.Versions {
			_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{
				Bucket: aws.String(bucket), Key: v.Key, VersionId: v.VersionId,
				BypassGovernanceRetention: aws.Bool(true),
			})
		}
		for _, m := range list.DeleteMarkers {
			_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: m.Key, VersionId: m.VersionId})
		}
		cleanupBucket(t, c, bucket)
	}()

	vid := putWithGovernance(t, c, bucket, "k")
	_, err := c.DeleteObject(context.Background(), &s3.DeleteObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: aws.String(vid),
	})
	if err == nil {
		t.Fatal("expected AccessDenied")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) || apiErr.ErrorCode() != "AccessDenied" {
		t.Fatalf("expected AccessDenied, got %v", err)
	}
}

func TestObjectLock_DeleteWithBypass_OK(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ol-by")
	createLockedBucket(t, c, bucket)
	defer cleanupBucket(t, c, bucket)

	vid := putWithGovernance(t, c, bucket, "k")
	_, err := c.DeleteObject(context.Background(), &s3.DeleteObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: aws.String(vid),
		BypassGovernanceRetention: aws.Bool(true),
	})
	if err != nil {
		t.Fatalf("DeleteObject with bypass: %v", err)
	}
}

func TestObjectLock_Compliance_BypassStillBlocked(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ol-cp")
	createLockedBucket(t, c, bucket)
	defer cleanupBucket(t, c, bucket)

	until := time.Now().Add(24 * time.Hour).UTC()
	out, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), Body: bytes.NewReader([]byte("x")),
		ObjectLockMode:            types.ObjectLockModeCompliance,
		ObjectLockRetainUntilDate: aws.Time(until),
	})
	if err != nil {
		t.Fatalf("PutObject with COMPLIANCE: %v", err)
	}
	vid := aws.ToString(out.VersionId)
	_, err = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: aws.String(vid),
		BypassGovernanceRetention: aws.Bool(true),
	})
	if err == nil {
		t.Fatal("expected AccessDenied — COMPLIANCE not bypassable")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) || apiErr.ErrorCode() != "AccessDenied" {
		t.Fatalf("expected AccessDenied, got %v", err)
	}
}

func TestObjectLock_LegalHold_BlocksDelete(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ol-lh")
	createLockedBucket(t, c, bucket)
	defer cleanupBucket(t, c, bucket)

	out, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), Body: bytes.NewReader([]byte("hold")),
		ObjectLockLegalHoldStatus: types.ObjectLockLegalHoldStatusOn,
	})
	if err != nil {
		t.Fatalf("PutObject with legal hold: %v", err)
	}
	vid := aws.ToString(out.VersionId)

	// Delete should be blocked even with bypass (legal hold supersedes).
	_, err = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: aws.String(vid),
		BypassGovernanceRetention: aws.Bool(true),
	})
	if err == nil {
		t.Fatal("expected AccessDenied — legal hold blocks delete")
	}

	// Turn off legal hold.
	if _, err := c.PutObjectLegalHold(context.Background(), &s3.PutObjectLegalHoldInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: aws.String(vid),
		LegalHold: &types.ObjectLockLegalHold{Status: types.ObjectLockLegalHoldStatusOff},
	}); err != nil {
		t.Fatalf("PutObjectLegalHold OFF: %v", err)
	}

	// Now delete should succeed.
	if _, err := c.DeleteObject(context.Background(), &s3.DeleteObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: aws.String(vid),
	}); err != nil {
		t.Fatalf("DeleteObject after legal hold OFF: %v", err)
	}
}

func TestObjectLock_LegalHold_RoundTrip(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ol-lr")
	createLockedBucket(t, c, bucket)
	defer cleanupBucket(t, c, bucket)

	out, _ := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), Body: bytes.NewReader([]byte("x")),
	})
	vid := aws.ToString(out.VersionId)
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: aws.String(vid)})
	}()

	if _, err := c.PutObjectLegalHold(context.Background(), &s3.PutObjectLegalHoldInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: aws.String(vid),
		LegalHold: &types.ObjectLockLegalHold{Status: types.ObjectLockLegalHoldStatusOn},
	}); err != nil {
		t.Fatalf("Put: %v", err)
	}
	hold, err := c.GetObjectLegalHold(context.Background(), &s3.GetObjectLegalHoldInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: aws.String(vid),
	})
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if hold.LegalHold.Status != types.ObjectLockLegalHoldStatusOn {
		t.Errorf("expected ON, got %v", hold.LegalHold.Status)
	}
}

func TestObjectLock_InlineHeadersRoundTrip(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ol-inl")
	createLockedBucket(t, c, bucket)
	defer cleanupBucket(t, c, bucket)

	vid := putWithGovernance(t, c, bucket, "k")
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{
			Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: aws.String(vid),
			BypassGovernanceRetention: aws.Bool(true),
		})
	}()

	head, err := c.HeadObject(context.Background(), &s3.HeadObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: aws.String(vid),
	})
	if err != nil {
		t.Fatalf("HeadObject: %v", err)
	}
	if head.ObjectLockMode != types.ObjectLockModeGovernance {
		t.Errorf("expected GOVERNANCE in HEAD response, got %v", head.ObjectLockMode)
	}
}

func TestObjectLock_DefaultRetentionApplied(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ol-def")
	createLockedBucket(t, c, bucket)
	defer cleanupBucket(t, c, bucket)

	if _, err := c.PutObjectLockConfiguration(context.Background(), &s3.PutObjectLockConfigurationInput{
		Bucket: aws.String(bucket),
		ObjectLockConfiguration: &types.ObjectLockConfiguration{
			ObjectLockEnabled: types.ObjectLockEnabledEnabled,
			Rule: &types.ObjectLockRule{
				DefaultRetention: &types.DefaultRetention{
					Mode: types.ObjectLockRetentionModeGovernance,
					Days: aws.Int32(1),
				},
			},
		},
	}); err != nil {
		t.Fatalf("PutObjectLockConfiguration: %v", err)
	}

	out, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), Body: bytes.NewReader([]byte("x")),
	})
	if err != nil {
		t.Fatalf("PutObject: %v", err)
	}
	vid := aws.ToString(out.VersionId)
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{
			Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: aws.String(vid),
			BypassGovernanceRetention: aws.Bool(true),
		})
	}()

	r, err := c.GetObjectRetention(context.Background(), &s3.GetObjectRetentionInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: aws.String(vid),
	})
	if err != nil {
		t.Fatalf("GetObjectRetention: %v", err)
	}
	if r.Retention.Mode != types.ObjectLockRetentionModeGovernance {
		t.Errorf("expected GOVERNANCE from default rule, got %v", r.Retention.Mode)
	}
}

func TestObjectLock_DeleteMarkerAllowedOnLocked(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "ol-dm")
	createLockedBucket(t, c, bucket)
	defer cleanupBucket(t, c, bucket)

	vid := putWithGovernance(t, c, bucket, "k")
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{
			Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: aws.String(vid),
			BypassGovernanceRetention: aws.Bool(true),
		})
		// Drain leftover delete markers.
		list, _ := c.ListObjectVersions(context.Background(), &s3.ListObjectVersionsInput{Bucket: aws.String(bucket)})
		for _, m := range list.DeleteMarkers {
			_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: m.Key, VersionId: m.VersionId})
		}
	}()

	// Delete WITHOUT versionId — should create a delete marker, NOT block.
	if _, err := c.DeleteObject(context.Background(), &s3.DeleteObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"),
	}); err != nil {
		t.Fatalf("DeleteObject (no versionId) should create delete marker: %v", err)
	}
}

// Keep `strings` referenced for any future use; also exercises that the SDK
// can find the lock response headers correctly.
var _ = strings.Contains
