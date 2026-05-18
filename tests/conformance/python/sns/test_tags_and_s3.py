"""SNS tags + S3 → SNS → SQS multi-hop conformance — Phase E of v0.4.0."""

from __future__ import annotations

import json
import secrets
import time

import boto3
import pytest
from botocore.config import Config

from conftest import endpoint, best_effort_delete_bucket, empty_bucket


def _make_sns():
    return boto3.client(
        "sns", endpoint_url=endpoint(), region_name="us-east-1",
        aws_access_key_id="test", aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 1}),
    )


def _make_sqs():
    return boto3.client(
        "sqs", endpoint_url=endpoint(), region_name="us-east-1",
        aws_access_key_id="test", aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 1}),
    )


@pytest.fixture
def sns():
    return _make_sns()


@pytest.fixture
def sqs():
    return _make_sqs()


# ---------- Tags ----------


def test_tag_resource_round_trip(sns):
    arn = sns.create_topic(Name=f"t_{secrets.token_hex(4)}")["TopicArn"]
    try:
        sns.tag_resource(ResourceArn=arn, Tags=[
            {"Key": "env", "Value": "dev"},
            {"Key": "team", "Value": "infra"},
        ])
        out = sns.list_tags_for_resource(ResourceArn=arn)
        tags = {t["Key"]: t["Value"] for t in out["Tags"]}
        assert tags == {"env": "dev", "team": "infra"}
    finally:
        sns.delete_topic(TopicArn=arn)


def test_untag_resource_removes_keys(sns):
    arn = sns.create_topic(Name=f"t_{secrets.token_hex(4)}")["TopicArn"]
    try:
        sns.tag_resource(ResourceArn=arn, Tags=[
            {"Key": "a", "Value": "1"},
            {"Key": "b", "Value": "2"},
        ])
        sns.untag_resource(ResourceArn=arn, TagKeys=["a"])
        out = sns.list_tags_for_resource(ResourceArn=arn)
        tags = {t["Key"]: t["Value"] for t in out["Tags"]}
        assert tags == {"b": "2"}
    finally:
        sns.delete_topic(TopicArn=arn)


def test_list_tags_on_untagged_returns_empty(sns):
    arn = sns.create_topic(Name=f"t_{secrets.token_hex(4)}")["TopicArn"]
    try:
        out = sns.list_tags_for_resource(ResourceArn=arn)
        assert out["Tags"] == []
    finally:
        sns.delete_topic(TopicArn=arn)


# ---------- S3 → SNS → SQS multi-hop ----------


def test_s3_to_sns_to_sqs_multi_hop(sns, sqs):
    """The strategic flow: PutBucketNotificationConfiguration with a
    TopicConfiguration, S3 PutObject fires to SNS, SNS fans out to the
    subscribed SQS queue."""
    s3 = boto3.client(
        "s3", endpoint_url=endpoint(), region_name="us-east-1",
        aws_access_key_id="test", aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 1}),
    )
    tname = f"t_{secrets.token_hex(4)}"
    qname = f"q_{secrets.token_hex(4)}"
    bucket = f"b-{secrets.token_hex(4)}"

    topic_arn = sns.create_topic(Name=tname)["TopicArn"]
    queue_url = sqs.create_queue(QueueName=qname)["QueueUrl"]
    queue_arn = f"arn:aws:sqs:us-east-1:000000000000:{qname}"

    try:
        sns.subscribe(TopicArn=topic_arn, Protocol="sqs", Endpoint=queue_arn)
        s3.create_bucket(Bucket=bucket)
        s3.put_bucket_notification_configuration(
            Bucket=bucket,
            NotificationConfiguration={
                "TopicConfigurations": [{
                    "TopicArn": topic_arn,
                    "Events": ["s3:ObjectCreated:*"],
                }],
            },
        )
        s3.put_object(Bucket=bucket, Key="hello.txt", Body=b"world")

        # Drain SQS — should have one message: SNS envelope wrapping S3 event.
        deadline = time.time() + 5
        msgs = []
        while time.time() < deadline:
            out = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=10, WaitTimeSeconds=1)
            got = out.get("Messages", [])
            if got:
                msgs = got
                break
        assert len(msgs) == 1
        sns_env = json.loads(msgs[0]["Body"])
        assert sns_env["Type"] == "Notification"
        assert sns_env["TopicArn"] == topic_arn
        # The Message field contains the S3 event envelope.
        s3_env = json.loads(sns_env["Message"])
        assert s3_env["Records"][0]["eventName"] == "s3:ObjectCreated:Put"
        assert s3_env["Records"][0]["s3"]["object"]["key"] == "hello.txt"
    finally:
        try:
            empty_bucket(s3, bucket)
            best_effort_delete_bucket(s3, bucket)
        except Exception:
            pass
        sns.delete_topic(TopicArn=topic_arn)
        sqs.delete_queue(QueueUrl=queue_url)
