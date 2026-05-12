package conformance

import (
	"bytes"
	"context"
	"errors"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsmiddleware "github.com/aws/aws-sdk-go-v2/aws/middleware"
	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	smithyhttp "github.com/aws/smithy-go/transport/http"
	smithymw "github.com/aws/smithy-go/middleware"
)

// injectIfMatch installs middleware that adds `If-Match: <value>` to the
// outgoing HTTP request. The pinned aws-sdk-go-v2 v1.61.2 predates the
// PutObjectInput.IfMatch field (added in late 2024); injecting via
// middleware exercises the server behaviour without an SDK upgrade.
func injectIfMatch(value string) func(*s3.Options) {
	return func(o *s3.Options) {
		o.APIOptions = append(o.APIOptions, func(stack *smithymw.Stack) error {
			return stack.Build.Add(smithymw.BuildMiddlewareFunc("inject-if-match",
				func(ctx context.Context, in smithymw.BuildInput, next smithymw.BuildHandler) (smithymw.BuildOutput, smithymw.Metadata, error) {
					req, ok := in.Request.(*smithyhttp.Request)
					if ok {
						req.Header.Set("If-Match", value)
					}
					return next.HandleBuild(ctx, in)
				},
			), smithymw.After)
		})
	}
}

var _ = awsmiddleware.RequestUserAgent{}

func TestConditionalPut_IfNoneMatchStar_Absent_OK(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cp-inmsabs")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	if _, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket:      aws.String(bucket),
		Key:         aws.String("k"),
		Body:        bytes.NewReader([]byte("first")),
		IfNoneMatch: aws.String("*"),
	}); err != nil {
		t.Fatalf("PUT IfNoneMatch=* on absent: %v", err)
	}
}

func TestConditionalPut_IfNoneMatchStar_Existing_Returns412(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cp-inmsexist")
	seedObject(t, c, bucket, "k", []byte("v"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	_, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket:      aws.String(bucket),
		Key:         aws.String("k"),
		Body:        bytes.NewReader([]byte("overwrite")),
		IfNoneMatch: aws.String("*"),
	})
	if err == nil {
		t.Fatal("expected 412, got nil")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 412 {
		t.Fatalf("expected HTTP 412, got %v", err)
	}
}

func TestConditionalPut_IfMatch_Match_Overwrites(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cp-ifm-ok")
	seedObject(t, c, bucket, "k", []byte("orig"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	head, err := c.HeadObject(context.Background(), &s3.HeadObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
	if err != nil {
		t.Fatalf("Head: %v", err)
	}
	etag := aws.ToString(head.ETag)

	if _, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("k"),
		Body:   bytes.NewReader([]byte("new")),
	}, injectIfMatch(etag)); err != nil {
		t.Fatalf("PUT IfMatch matching: %v", err)
	}
}

func TestConditionalPut_IfMatch_Stale_Returns412(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cp-ifm-stale")
	seedObject(t, c, bucket, "k", []byte("orig"))
	defer func() {
		_, _ = c.DeleteObject(context.Background(), &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String("k")})
		cleanupBucket(t, c, bucket)
	}()

	_, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("k"),
		Body:   bytes.NewReader([]byte("new")),
	}, injectIfMatch(`"deadbeef"`))
	if err == nil {
		t.Fatal("expected 412, got nil")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 412 {
		t.Fatalf("expected HTTP 412, got %v", err)
	}
}

func TestConditionalPut_IfMatch_Absent_Returns412(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "cp-ifm-abs")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	_, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String("k"),
		Body:   bytes.NewReader([]byte("v")),
	}, injectIfMatch(`"deadbeef"`))
	if err == nil {
		t.Fatal("expected 412, got nil")
	}
	var respErr *awshttp.ResponseError
	if !errors.As(err, &respErr) || respErr.HTTPStatusCode() != 412 {
		t.Fatalf("expected HTTP 412, got %v", err)
	}
}
