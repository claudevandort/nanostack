package conformance

import (
	"context"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

func TestNotification_TopicConfig_RoundTrip(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "notif-rt")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.PutBucketNotificationConfiguration(context.Background(), &s3.PutBucketNotificationConfigurationInput{
		Bucket: aws.String(bucket),
		NotificationConfiguration: &types.NotificationConfiguration{
			TopicConfigurations: []types.TopicConfiguration{
				{
					TopicArn: aws.String("arn:aws:sns:us-east-1:1:t"),
					Events:   []types.Event{types.EventS3ObjectCreatedPut},
				},
			},
		},
	}); err != nil {
		t.Fatalf("Put: %v", err)
	}
	out, err := c.GetBucketNotificationConfiguration(context.Background(), &s3.GetBucketNotificationConfigurationInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if len(out.TopicConfigurations) != 1 || aws.ToString(out.TopicConfigurations[0].TopicArn) != "arn:aws:sns:us-east-1:1:t" {
		t.Errorf("topic arn mismatch: %+v", out.TopicConfigurations)
	}
}

func TestNotification_QueueWithFilter(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "notif-q")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	if _, err := c.PutBucketNotificationConfiguration(context.Background(), &s3.PutBucketNotificationConfigurationInput{
		Bucket: aws.String(bucket),
		NotificationConfiguration: &types.NotificationConfiguration{
			QueueConfigurations: []types.QueueConfiguration{
				{
					QueueArn: aws.String("arn:aws:sqs:us-east-1:1:q"),
					Events:   []types.Event{types.EventS3ObjectCreated},
					Filter: &types.NotificationConfigurationFilter{
						Key: &types.S3KeyFilter{
							FilterRules: []types.FilterRule{{Name: types.FilterRuleNamePrefix, Value: aws.String("uploads/")}},
						},
					},
				},
			},
		},
	}); err != nil {
		t.Fatalf("Put: %v", err)
	}
	out, err := c.GetBucketNotificationConfiguration(context.Background(), &s3.GetBucketNotificationConfigurationInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if len(out.QueueConfigurations) != 1 {
		t.Fatalf("expected 1 queue config")
	}
	q := out.QueueConfigurations[0]
	if q.Filter == nil || q.Filter.Key == nil || len(q.Filter.Key.FilterRules) != 1 {
		t.Fatalf("filter missing")
	}
	if aws.ToString(q.Filter.Key.FilterRules[0].Value) != "uploads/" {
		t.Errorf("filter value mismatch")
	}
}

func TestNotification_EmptyOnUntouched(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "notif-no")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	out, err := c.GetBucketNotificationConfiguration(context.Background(), &s3.GetBucketNotificationConfigurationInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("Get on untouched should be 200 with empty config, got: %v", err)
	}
	if len(out.TopicConfigurations) != 0 || len(out.QueueConfigurations) != 0 || len(out.LambdaFunctionConfigurations) != 0 {
		t.Errorf("expected empty config, got %+v", out)
	}
}

func TestNotification_EmptyPutClears(t *testing.T) {
	c := newClient(t)
	bucket := uniqueBucketName(t, "notif-clr")
	if _, err := c.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	defer cleanupBucket(t, c, bucket)

	// Set then clear.
	if _, err := c.PutBucketNotificationConfiguration(context.Background(), &s3.PutBucketNotificationConfigurationInput{
		Bucket: aws.String(bucket),
		NotificationConfiguration: &types.NotificationConfiguration{
			TopicConfigurations: []types.TopicConfiguration{
				{TopicArn: aws.String("arn:aws:sns:us-east-1:1:t"), Events: []types.Event{types.EventS3ObjectCreatedPut}},
			},
		},
	}); err != nil {
		t.Fatalf("Put: %v", err)
	}
	if _, err := c.PutBucketNotificationConfiguration(context.Background(), &s3.PutBucketNotificationConfigurationInput{
		Bucket:                    aws.String(bucket),
		NotificationConfiguration: &types.NotificationConfiguration{},
	}); err != nil {
		t.Fatalf("empty Put: %v", err)
	}
	out, err := c.GetBucketNotificationConfiguration(context.Background(), &s3.GetBucketNotificationConfigurationInput{Bucket: aws.String(bucket)})
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if len(out.TopicConfigurations) != 0 {
		t.Errorf("empty Put should have cleared config")
	}
}
