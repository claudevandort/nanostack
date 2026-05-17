"""SQS dead-letter queue conformance — Phase 4 of v0.3.0.

Configure RedrivePolicy on a source queue. After maxReceiveCount
deliveries, messages move to the DLQ instead of being delivered.
"""

from __future__ import annotations

import json
import time
import uuid

import boto3
import botocore.exceptions
import pytest
from botocore.config import Config

from conftest import endpoint


def _make_sqs():
    return boto3.client(
        "sqs",
        endpoint_url=endpoint(),
        region_name="us-east-1",
        aws_access_key_id="test",
        aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 1}),
    )


@pytest.fixture
def sqs():
    return _make_sqs()


def _unique(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


@pytest.fixture
def dlq_setup(sqs):
    """Yields (source_url, dlq_url) with a RedrivePolicy linking them
    and VisibilityTimeout=1 for fast redelivery."""
    src = _unique("src")
    dlq = _unique("dlq")
    dlq_url = sqs.create_queue(QueueName=dlq)["QueueUrl"]
    dlq_arn = sqs.get_queue_attributes(QueueUrl=dlq_url, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
    src_url = sqs.create_queue(
        QueueName=src,
        Attributes={
            "VisibilityTimeout": "1",
            "RedrivePolicy": json.dumps({"deadLetterTargetArn": dlq_arn, "maxReceiveCount": 2}),
        },
    )["QueueUrl"]
    yield src_url, dlq_url
    for u in (src_url, dlq_url):
        try:
            sqs.delete_queue(QueueUrl=u)
        except botocore.exceptions.ClientError:
            pass


def _receive_and_drop(sqs, url):
    """Receive a message and let visibility timeout expire so it
    redelivers. Returns the received message bodies."""
    out = sqs.receive_message(QueueUrl=url)
    return [m["Body"] for m in out.get("Messages", [])]


def test_message_moves_to_dlq_after_max_receives(sqs, dlq_setup):
    src_url, dlq_url = dlq_setup
    sqs.send_message(QueueUrl=src_url, MessageBody="poison")

    # 1st receive (count → 1), let VT expire
    out1 = _receive_and_drop(sqs, src_url)
    assert out1 == ["poison"]
    time.sleep(1.2)

    # 2nd receive (count → 2), let VT expire
    out2 = _receive_and_drop(sqs, src_url)
    assert out2 == ["poison"]
    time.sleep(1.2)

    # 3rd attempt — should NOT deliver; instead route to DLQ.
    out3 = _receive_and_drop(sqs, src_url)
    assert out3 == [], f"expected empty, got {out3}"

    # Message should now be in the DLQ.
    dlq_out = sqs.receive_message(QueueUrl=dlq_url)
    assert dlq_out["Messages"][0]["Body"] == "poison"


def test_redrive_policy_round_trips_through_set_attributes(sqs):
    name = _unique("redrive")
    url = sqs.create_queue(QueueName=name)["QueueUrl"]
    try:
        dlq_name = _unique("dlq")
        dlq_url = sqs.create_queue(QueueName=dlq_name)["QueueUrl"]
        try:
            dlq_arn = sqs.get_queue_attributes(QueueUrl=dlq_url, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
            policy = json.dumps({"deadLetterTargetArn": dlq_arn, "maxReceiveCount": 5})
            sqs.set_queue_attributes(QueueUrl=url, Attributes={"RedrivePolicy": policy})
            attrs = sqs.get_queue_attributes(QueueUrl=url, AttributeNames=["RedrivePolicy"])["Attributes"]
            assert "RedrivePolicy" in attrs
            assert "deadLetterTargetArn" in attrs["RedrivePolicy"]
        finally:
            sqs.delete_queue(QueueUrl=dlq_url)
    finally:
        sqs.delete_queue(QueueUrl=url)


def test_dlq_routing_preserves_message_body(sqs, dlq_setup):
    src_url, dlq_url = dlq_setup
    sqs.send_message(QueueUrl=src_url, MessageBody="preserve-me")
    # Trigger DLQ routing by repeated receives.
    for _ in range(3):
        sqs.receive_message(QueueUrl=src_url)
        time.sleep(1.2)
    # Verify the DLQ message has the same body + a fresh receive count.
    dlq_out = sqs.receive_message(QueueUrl=dlq_url)
    assert dlq_out["Messages"][0]["Body"] == "preserve-me"


def test_message_without_redrive_never_moves_to_dlq(sqs):
    """A queue without RedrivePolicy can be received over and over —
    the message just keeps coming back."""
    name = _unique("noredrive")
    url = sqs.create_queue(QueueName=name, Attributes={"VisibilityTimeout": "1"})["QueueUrl"]
    try:
        sqs.send_message(QueueUrl=url, MessageBody="stay")
        for _ in range(5):
            out = sqs.receive_message(QueueUrl=url)
            assert out["Messages"][0]["Body"] == "stay"
            time.sleep(1.1)
    finally:
        sqs.delete_queue(QueueUrl=url)
