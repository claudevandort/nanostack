"""SNS Publish + PublishBatch + SNS → SQS conformance — Phase D of v0.4.0."""

from __future__ import annotations

import json
import secrets
import time

import boto3
import pytest
from botocore.config import Config

from conftest import endpoint


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


def _setup(sns, sqs, raw_message_delivery: bool = False):
    """Create a topic + queue + sub. Return (topic_arn, queue_url, sub_arn)."""
    tname = f"t_{secrets.token_hex(4)}"
    qname = f"q_{secrets.token_hex(4)}"
    topic_arn = sns.create_topic(Name=tname)["TopicArn"]
    queue_url = sqs.create_queue(QueueName=qname)["QueueUrl"]
    queue_arn = f"arn:aws:sqs:us-east-1:000000000000:{qname}"
    sub_arn = sns.subscribe(TopicArn=topic_arn, Protocol="sqs", Endpoint=queue_arn)["SubscriptionArn"]
    if raw_message_delivery:
        sns.set_subscription_attributes(
            SubscriptionArn=sub_arn,
            AttributeName="RawMessageDelivery",
            AttributeValue="true",
        )
    return topic_arn, queue_url, sub_arn


def _drain(sqs, queue_url, max_wait_s=3.0):
    deadline = time.time() + max_wait_s
    msgs = []
    while time.time() < deadline:
        out = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=10, WaitTimeSeconds=1)
        got = out.get("Messages", [])
        if not got:
            if msgs:
                return msgs
            continue
        for m in got:
            msgs.append(m)
            sqs.delete_message(QueueUrl=queue_url, ReceiptHandle=m["ReceiptHandle"])
    return msgs


def test_publish_to_topic_delivers_envelope_to_sqs(sns, sqs):
    topic_arn, queue_url, _ = _setup(sns, sqs)
    try:
        out = sns.publish(TopicArn=topic_arn, Message="hello")
        assert "MessageId" in out
        msgs = _drain(sqs, queue_url)
        assert len(msgs) == 1
        body = json.loads(msgs[0]["Body"])
        assert body["Type"] == "Notification"
        assert body["TopicArn"] == topic_arn
        assert body["Message"] == "hello"
        assert "MessageId" in body
        assert "Timestamp" in body
    finally:
        sns.delete_topic(TopicArn=topic_arn)
        sqs.delete_queue(QueueUrl=queue_url)


def test_publish_with_raw_message_delivery(sns, sqs):
    topic_arn, queue_url, _ = _setup(sns, sqs, raw_message_delivery=True)
    try:
        sns.publish(TopicArn=topic_arn, Message="raw-bytes")
        msgs = _drain(sqs, queue_url)
        assert len(msgs) == 1
        # Raw mode: body is the message verbatim, not an envelope.
        assert msgs[0]["Body"] == "raw-bytes"
    finally:
        sns.delete_topic(TopicArn=topic_arn)
        sqs.delete_queue(QueueUrl=queue_url)


def test_publish_with_subject(sns, sqs):
    topic_arn, queue_url, _ = _setup(sns, sqs)
    try:
        sns.publish(TopicArn=topic_arn, Subject="alert", Message="message-body")
        msgs = _drain(sqs, queue_url)
        body = json.loads(msgs[0]["Body"])
        assert body["Subject"] == "alert"
    finally:
        sns.delete_topic(TopicArn=topic_arn)
        sqs.delete_queue(QueueUrl=queue_url)


def test_publish_with_no_subscriptions_succeeds(sns):
    """Publishing to a topic with no subscribers is a no-op success."""
    tname = f"t_{secrets.token_hex(4)}"
    topic_arn = sns.create_topic(Name=tname)["TopicArn"]
    try:
        out = sns.publish(TopicArn=topic_arn, Message="lonely")
        assert "MessageId" in out
    finally:
        sns.delete_topic(TopicArn=topic_arn)


def test_publish_to_missing_topic_returns_404(sns):
    import botocore.exceptions
    with pytest.raises(botocore.exceptions.ClientError) as exc:
        sns.publish(
            TopicArn="arn:aws:sns:us-east-1:000000000000:does-not-exist",
            Message="x",
        )
    assert exc.value.response["Error"]["Code"] == "NotFound"


def test_publish_message_id_is_unique(sns, sqs):
    topic_arn, queue_url, _ = _setup(sns, sqs)
    try:
        ids = set()
        for _ in range(3):
            out = sns.publish(TopicArn=topic_arn, Message="m")
            ids.add(out["MessageId"])
        assert len(ids) == 3
    finally:
        sns.delete_topic(TopicArn=topic_arn)
        sqs.delete_queue(QueueUrl=queue_url)


def test_publish_fans_out_to_multiple_subscribers(sns, sqs):
    """Two SQS subs → both receive the published message."""
    tname = f"t_{secrets.token_hex(4)}"
    q1 = f"q_{secrets.token_hex(4)}"
    q2 = f"q_{secrets.token_hex(4)}"
    topic_arn = sns.create_topic(Name=tname)["TopicArn"]
    u1 = sqs.create_queue(QueueName=q1)["QueueUrl"]
    u2 = sqs.create_queue(QueueName=q2)["QueueUrl"]
    try:
        sns.subscribe(TopicArn=topic_arn, Protocol="sqs",
                      Endpoint=f"arn:aws:sqs:us-east-1:000000000000:{q1}")
        sns.subscribe(TopicArn=topic_arn, Protocol="sqs",
                      Endpoint=f"arn:aws:sqs:us-east-1:000000000000:{q2}")
        sns.publish(TopicArn=topic_arn, Message="fan-out")
        assert len(_drain(sqs, u1)) == 1
        assert len(_drain(sqs, u2)) == 1
    finally:
        sns.delete_topic(TopicArn=topic_arn)
        sqs.delete_queue(QueueUrl=u1)
        sqs.delete_queue(QueueUrl=u2)


def test_publish_batch_per_entry_success(sns, sqs):
    topic_arn, queue_url, _ = _setup(sns, sqs)
    try:
        out = sns.publish_batch(
            TopicArn=topic_arn,
            PublishBatchRequestEntries=[
                {"Id": "e1", "Message": "msg1"},
                {"Id": "e2", "Message": "msg2"},
                {"Id": "e3", "Message": "msg3"},
            ],
        )
        ids = sorted(e["Id"] for e in out["Successful"])
        assert ids == ["e1", "e2", "e3"]
        msgs = _drain(sqs, queue_url)
        assert len(msgs) == 3
    finally:
        sns.delete_topic(TopicArn=topic_arn)
        sqs.delete_queue(QueueUrl=queue_url)
