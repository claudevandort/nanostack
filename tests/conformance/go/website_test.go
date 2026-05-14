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

func TestWebsite_IndexAndError_RoundTrip(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "web-idx")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.PutBucketWebsite(context.Background(), &s3.PutBucketWebsiteInput{
		Bucket: aws.String(bucket),
		WebsiteConfiguration: &types.WebsiteConfiguration{
			IndexDocument: &types.IndexDocument{Suffix: aws.String("index.html")},
			ErrorDocument: &types.ErrorDocument{Key: aws.String("404.html")},
		},
	}); err != nil {
		t.Fatalf("Put: %v", err)
	}
	out, err := c.GetBucketWebsite(context.Background(), &s3.GetBucketWebsiteInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if aws.ToString(out.IndexDocument.Suffix) != "index.html" {
		t.Errorf("index suffix mismatch")
	}
	if aws.ToString(out.ErrorDocument.Key) != "404.html" {
		t.Errorf("error key mismatch")
	}
}

func TestWebsite_RedirectAllRequestsTo(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "web-ra")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.PutBucketWebsite(context.Background(), &s3.PutBucketWebsiteInput{
		Bucket: aws.String(bucket),
		WebsiteConfiguration: &types.WebsiteConfiguration{
			RedirectAllRequestsTo: &types.RedirectAllRequestsTo{
				HostName: aws.String("example.com"),
				Protocol: types.ProtocolHttps,
			},
		},
	}); err != nil {
		t.Fatalf("Put: %v", err)
	}
	out, err := c.GetBucketWebsite(context.Background(), &s3.GetBucketWebsiteInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if aws.ToString(out.RedirectAllRequestsTo.HostName) != "example.com" {
		t.Errorf("host mismatch")
	}
	if out.RedirectAllRequestsTo.Protocol != types.ProtocolHttps {
		t.Errorf("protocol mismatch")
	}
}

func TestWebsite_GetOnUntouched_404(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "web-no")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	_, err := c.GetBucketWebsite(context.Background(), &s3.GetBucketWebsiteInput{Bucket: aws.String(bucket)})
	if err == nil {
		t.Fatal("expected NoSuchWebsiteConfiguration")
	}
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) || apiErr.ErrorCode() != "NoSuchWebsiteConfiguration" {
		t.Fatalf("expected NoSuchWebsiteConfiguration, got %v", err)
	}
}

func TestWebsite_Delete_Idempotent(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "web-del")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.DeleteBucketWebsite(context.Background(), &s3.DeleteBucketWebsiteInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("first delete: %v", err)
	}
}
