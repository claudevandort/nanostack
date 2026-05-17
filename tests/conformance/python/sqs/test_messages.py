"""SQS message conformance — Phase 2 of v0.3.0.

SendMessage / ReceiveMessage / DeleteMessage / ChangeMessageVisibility.
Long polling lands in Phase 3.
"""

from __future__ import annotations

import hashlib
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
def queue_url(sqs):
    name = _unique("msg")
    url = sqs.create_queue(QueueName=name)["QueueUrl"]
    yield url
    try:
        sqs.delete_queue(QueueUrl=url)
    except botocore.exceptions.ClientError:
        pass


@pytest.fixture
def short_vt_queue(sqs):
    """A queue with VisibilityTimeout=1 so visibility-timeout tests run fast."""
    name = _unique("svt")
    url = sqs.create_queue(QueueName=name, Attributes={"VisibilityTimeout": "1"})["QueueUrl"]
    yield url
    try:
        sqs.delete_queue(QueueUrl=url)
    except botocore.exceptions.ClientError:
        pass


# ---------------------------------------------------------------------------
# SendMessage


def test_send_returns_id_and_md5(sqs, queue_url):
    body = "hello world"
    out = sqs.send_message(QueueUrl=queue_url, MessageBody=body)
    assert "MessageId" in out
    expected_md5 = hashlib.md5(body.encode()).hexdigest()
    assert out["MD5OfMessageBody"] == expected_md5


def test_send_to_missing_queue_returns_not_found(sqs):
    fake = "http://127.0.0.1:14566/000000000000/nonexistent_q_xyz"
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        sqs.send_message(QueueUrl=fake, MessageBody="x")
    assert ei.value.response["Error"]["Code"] == "AWS.SimpleQueueService.NonExistentQueue"


# ---------------------------------------------------------------------------
# ReceiveMessage


def test_receive_returns_recently_sent(sqs, queue_url):
    sqs.send_message(QueueUrl=queue_url, MessageBody="m1")
    out = sqs.receive_message(QueueUrl=queue_url)
    assert "Messages" in out
    assert out["Messages"][0]["Body"] == "m1"
    assert "ReceiptHandle" in out["Messages"][0]


def test_receive_empty_queue_returns_no_messages_key(sqs, queue_url):
    out = sqs.receive_message(QueueUrl=queue_url)
    # boto3 normalises absent Messages to missing key.
    assert "Messages" not in out or out["Messages"] == []


def test_receive_respects_max_messages(sqs, queue_url):
    for i in range(5):
        sqs.send_message(QueueUrl=queue_url, MessageBody=f"m{i}")
    out = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=3)
    assert len(out["Messages"]) == 3


def test_visibility_timeout_hides_then_redelivers(sqs, short_vt_queue):
    sqs.send_message(QueueUrl=short_vt_queue, MessageBody="reappear")
    out1 = sqs.receive_message(QueueUrl=short_vt_queue)
    assert out1["Messages"][0]["Body"] == "reappear"
    # Immediately receive again — should be empty (in-flight).
    out_empty = sqs.receive_message(QueueUrl=short_vt_queue)
    assert "Messages" not in out_empty or out_empty["Messages"] == []
    # After visibility-timeout (1s), the message reappears.
    time.sleep(1.5)
    out2 = sqs.receive_message(QueueUrl=short_vt_queue)
    assert out2["Messages"][0]["Body"] == "reappear"


def test_per_call_visibility_timeout_override(sqs, queue_url):
    sqs.send_message(QueueUrl=queue_url, MessageBody="m")
    # Force a 0-second visibility so a second receive succeeds.
    out = sqs.receive_message(QueueUrl=queue_url, VisibilityTimeout=0)
    assert out["Messages"][0]["Body"] == "m"
    out2 = sqs.receive_message(QueueUrl=queue_url)
    assert out2["Messages"][0]["Body"] == "m"


def test_send_with_delay_hides_message(sqs, queue_url):
    sqs.send_message(QueueUrl=queue_url, MessageBody="delayed", DelaySeconds=1)
    out_empty = sqs.receive_message(QueueUrl=queue_url)
    assert "Messages" not in out_empty or out_empty["Messages"] == []
    time.sleep(1.5)
    out2 = sqs.receive_message(QueueUrl=queue_url)
    assert out2["Messages"][0]["Body"] == "delayed"


# ---------------------------------------------------------------------------
# DeleteMessage


def test_delete_removes_message(sqs, queue_url):
    sqs.send_message(QueueUrl=queue_url, MessageBody="del-me")
    out = sqs.receive_message(QueueUrl=queue_url)
    sqs.delete_message(QueueUrl=queue_url, ReceiptHandle=out["Messages"][0]["ReceiptHandle"])
    # Even after visibility timeout, message is gone.
    out2 = sqs.receive_message(QueueUrl=queue_url, VisibilityTimeout=0)
    assert "Messages" not in out2 or out2["Messages"] == []


def test_delete_with_invalid_receipt_returns_validation(sqs, queue_url):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        sqs.delete_message(QueueUrl=queue_url, ReceiptHandle="not-a-real-handle")
    assert ei.value.response["Error"]["Code"] == "ReceiptHandleIsInvalid"


def test_delete_idempotent_on_already_deleted(sqs, queue_url):
    # AWS-real: a second DeleteMessage on the same message is a no-op.
    sqs.send_message(QueueUrl=queue_url, MessageBody="x")
    out = sqs.receive_message(QueueUrl=queue_url)
    handle = out["Messages"][0]["ReceiptHandle"]
    sqs.delete_message(QueueUrl=queue_url, ReceiptHandle=handle)
    sqs.delete_message(QueueUrl=queue_url, ReceiptHandle=handle)  # should not raise


# ---------------------------------------------------------------------------
# ChangeMessageVisibility


def test_change_visibility_extends_in_flight(sqs, short_vt_queue):
    sqs.send_message(QueueUrl=short_vt_queue, MessageBody="extend-me")
    out = sqs.receive_message(QueueUrl=short_vt_queue)
    handle = out["Messages"][0]["ReceiptHandle"]
    # Extend visibility by 10s; message should not reappear quickly.
    sqs.change_message_visibility(QueueUrl=short_vt_queue, ReceiptHandle=handle, VisibilityTimeout=10)
    time.sleep(1.5)
    out_still_empty = sqs.receive_message(QueueUrl=short_vt_queue)
    assert "Messages" not in out_still_empty or out_still_empty["Messages"] == []


def test_change_visibility_to_zero_makes_visible(sqs, queue_url):
    sqs.send_message(QueueUrl=queue_url, MessageBody="release-me")
    out = sqs.receive_message(QueueUrl=queue_url)
    handle = out["Messages"][0]["ReceiptHandle"]
    sqs.change_message_visibility(QueueUrl=queue_url, ReceiptHandle=handle, VisibilityTimeout=0)
    out2 = sqs.receive_message(QueueUrl=queue_url)
    assert out2["Messages"][0]["Body"] == "release-me"


# ---------------------------------------------------------------------------
# PurgeQueue


def test_purge_clears_messages(sqs, queue_url):
    for i in range(3):
        sqs.send_message(QueueUrl=queue_url, MessageBody=f"m{i}")
    sqs.purge_queue(QueueUrl=queue_url)
    out = sqs.receive_message(QueueUrl=queue_url, VisibilityTimeout=0)
    assert "Messages" not in out or out["Messages"] == []
