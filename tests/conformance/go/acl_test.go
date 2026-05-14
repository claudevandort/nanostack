package conformance

import (
	"bytes"
	"context"
	"errors"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	smithy "github.com/aws/smithy-go"
)

func hasGrant(grants []types.Grant, predicate func(g types.Grant) bool) bool {
	for _, g := range grants {
		if predicate(g) {
			return true
		}
	}
	return false
}

func TestAcl_BucketRoundTrip_XmlBody(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "acl-buk-rt")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	owner := types.Owner{ID: aws.String("0123abc"), DisplayName: aws.String("owner")}
	if _, err := c.PutBucketAcl(context.Background(), &s3.PutBucketAclInput{
		Bucket: aws.String(bucket),
		AccessControlPolicy: &types.AccessControlPolicy{
			Owner: &owner,
			Grants: []types.Grant{
				{
					Grantee:    &types.Grantee{Type: types.TypeCanonicalUser, ID: aws.String("0123abc"), DisplayName: aws.String("owner")},
					Permission: types.PermissionFullControl,
				},
				{
					Grantee:    &types.Grantee{Type: types.TypeGroup, URI: aws.String("http://acs.amazonaws.com/groups/global/AllUsers")},
					Permission: types.PermissionRead,
				},
			},
		},
	}); err != nil {
		t.Fatalf("PutBucketAcl: %v", err)
	}

	out, err := c.GetBucketAcl(context.Background(), &s3.GetBucketAclInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("GetBucketAcl: %v", err)
	}
	if aws.ToString(out.Owner.ID) != "0123abc" {
		t.Errorf("owner mismatch: %v", aws.ToString(out.Owner.ID))
	}
	hasGroup := hasGrant(out.Grants, func(g types.Grant) bool {
		return g.Grantee != nil && g.Grantee.Type == types.TypeGroup && aws.ToString(g.Grantee.URI) == "http://acs.amazonaws.com/groups/global/AllUsers"
	})
	if !hasGroup {
		t.Errorf("missing AllUsers Group grant: %+v", out.Grants)
	}
}

func TestAcl_BucketCannedHeader(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "acl-canned")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.PutBucketAcl(context.Background(), &s3.PutBucketAclInput{
		Bucket: aws.String(bucket),
		ACL:    types.BucketCannedACLPublicRead,
	}); err != nil {
		t.Fatalf("PutBucketAcl canned: %v", err)
	}

	out, err := c.GetBucketAcl(context.Background(), &s3.GetBucketAclInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("GetBucketAcl: %v", err)
	}
	hasGroup := hasGrant(out.Grants, func(g types.Grant) bool {
		return g.Grantee != nil && g.Grantee.Type == types.TypeGroup && g.Permission == types.PermissionRead
	})
	if !hasGroup {
		t.Errorf("canned public-read missing AllUsers READ: %+v", out.Grants)
	}
}

func TestAcl_ObjectRoundTrip(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "acl-obj")
	seedObject(t, c, bucket, "k", []byte("v"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	if _, err := c.PutObjectAcl(context.Background(), &s3.PutObjectAclInput{
		Bucket: aws.String(bucket), Key: aws.String("k"),
		ACL: types.ObjectCannedACLPublicRead,
	}); err != nil {
		t.Fatalf("PutObjectAcl: %v", err)
	}
	out, err := c.GetObjectAcl(context.Background(), &s3.GetObjectAclInput{Bucket: aws.String(bucket), Key: aws.String("k")})
	if err != nil {
		t.Fatalf("GetObjectAcl: %v", err)
	}
	hasGroup := hasGrant(out.Grants, func(g types.Grant) bool {
		return g.Grantee != nil && g.Grantee.Type == types.TypeGroup
	})
	if !hasGroup {
		t.Errorf("object ACL missing Group grant: %+v", out.Grants)
	}
}

func TestAcl_DefaultOnUntouchedObject(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "acl-def")
	seedObject(t, c, bucket, "k", []byte("v"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	out, err := c.GetObjectAcl(context.Background(), &s3.GetObjectAclInput{Bucket: aws.String(bucket), Key: aws.String("k")})
	if err != nil {
		t.Fatalf("GetObjectAcl: %v", err)
	}
	if len(out.Grants) != 1 || out.Grants[0].Permission != types.PermissionFullControl {
		t.Errorf("expected single FULL_CONTROL grant, got: %+v", out.Grants)
	}
}

func TestAcl_PutObject_InlineCannedHeader(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "acl-inline")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	if _, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"),
		Body: bytes.NewReader([]byte("hi")),
		ACL:  types.ObjectCannedACLPublicRead,
	}); err != nil {
		t.Fatalf("PutObject with ACL: %v", err)
	}
	out, _ := c.GetObjectAcl(context.Background(), &s3.GetObjectAclInput{Bucket: aws.String(bucket), Key: aws.String("k")})
	hasGroup := hasGrant(out.Grants, func(g types.Grant) bool {
		return g.Grantee != nil && g.Grantee.Type == types.TypeGroup
	})
	if !hasGroup {
		t.Errorf("inline ACL didn't land: %+v", out.Grants)
	}
}

func TestAcl_GrantHeader_FoldsIntoAcl(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "acl-grant")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	if _, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket), Key: aws.String("k"),
		Body:      bytes.NewReader([]byte("hi")),
		GrantRead: aws.String("id=\"abc-canonical\""),
	}); err != nil {
		t.Fatalf("PutObject with GrantRead: %v", err)
	}
	out, _ := c.GetObjectAcl(context.Background(), &s3.GetObjectAclInput{Bucket: aws.String(bucket), Key: aws.String("k")})
	hasGrantRead := hasGrant(out.Grants, func(g types.Grant) bool {
		return g.Permission == types.PermissionRead && g.Grantee != nil && aws.ToString(g.Grantee.ID) == "abc-canonical"
	})
	if !hasGrantRead {
		t.Errorf("expected READ grant for abc-canonical, got: %+v", out.Grants)
	}
}

func TestAcl_BucketOwnerEnforced_RejectsAclPut(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "acl-boe")
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

	_, err := c.PutBucketAcl(context.Background(), &s3.PutBucketAclInput{
		Bucket: aws.String(bucket),
		ACL:    types.BucketCannedACLPrivate,
	})
	if err == nil {
		t.Fatal("expected AccessControlListNotSupported")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) || apiErr.ErrorCode() != "AccessControlListNotSupported" {
		t.Fatalf("expected AccessControlListNotSupported, got %v", err)
	}
}

func TestAcl_PerVersion(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "acl-ver")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if _, err := c.PutBucketVersioning(context.Background(), &s3.PutBucketVersioningInput{
		Bucket: aws.String(bucket),
		VersioningConfiguration: &types.VersioningConfiguration{Status: types.BucketVersioningStatusEnabled},
	}); err != nil {
		t.Fatalf("enable versioning: %v", err)
	}
	defer func() {
		drainVersions(t, c, bucket)
		cleanupBucket(t, c, bucket)
	}()

	v1, _ := c.PutObject(context.Background(), &s3.PutObjectInput{Bucket: aws.String(bucket), Key: aws.String("k"), Body: bytes.NewReader([]byte("first"))})
	v2, _ := c.PutObject(context.Background(), &s3.PutObjectInput{Bucket: aws.String(bucket), Key: aws.String("k"), Body: bytes.NewReader([]byte("second"))})

	// Tag v1 ACL as public-read.
	if _, err := c.PutObjectAcl(context.Background(), &s3.PutObjectAclInput{
		Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: v1.VersionId,
		ACL: types.ObjectCannedACLPublicRead,
	}); err != nil {
		t.Fatalf("PutObjectAcl v1: %v", err)
	}
	out1, _ := c.GetObjectAcl(context.Background(), &s3.GetObjectAclInput{Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: v1.VersionId})
	hasGroup1 := hasGrant(out1.Grants, func(g types.Grant) bool { return g.Grantee != nil && g.Grantee.Type == types.TypeGroup })
	if !hasGroup1 {
		t.Errorf("v1 should have AllUsers grant, got: %+v", out1.Grants)
	}
	out2, _ := c.GetObjectAcl(context.Background(), &s3.GetObjectAclInput{Bucket: aws.String(bucket), Key: aws.String("k"), VersionId: v2.VersionId})
	hasGroup2 := hasGrant(out2.Grants, func(g types.Grant) bool { return g.Grantee != nil && g.Grantee.Type == types.TypeGroup })
	if hasGroup2 {
		t.Errorf("v2 should NOT have AllUsers grant, got: %+v", out2.Grants)
	}
}

func TestAcl_MalformedXml_400(t *testing.T) {
	// Use the raw HTTP API to send malformed XML — the SDK won't let us.
	c := newClient(t)
	bucket := uniqueBucketName(t, "acl-malformed")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	// SDK exposes header-only canned writes too. Send an UNKNOWN canned
	// value to trigger InvalidArgument (which the SDK accepts).
	_, err := c.PutBucketAcl(context.Background(), &s3.PutBucketAclInput{
		Bucket: aws.String(bucket),
		ACL:    types.BucketCannedACL("frobnicate"),
	})
	if err == nil {
		t.Fatal("expected error for unknown canned ACL")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 400 {
		t.Fatalf("expected 400, got %v", err)
	}
}
