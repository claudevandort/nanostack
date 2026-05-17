"""SQS batch + long-polling conformance — Phase 3 of v0.3.0.

SendMessageBatch / DeleteMessageBatch / ChangeMessageVisibilityBatch
plus the WaitTimeSeconds long-polling path on ReceiveMessage.
"""

from __future__ import annotations

import threading
import time
import uuid

import boto3
import botocore.exceptions
import pytest
from botocore.config import Config

from conftest import endpoint


def _make_sqs(read_timeout: int = 30):
    return boto3.client(
        "sqs",
        endpoint_url=endpoint(),
        region_name="us-east-1",
        aws_access_key_id="test",
        aws_secret_access_key="test",
        config=Config(
            retries={"max_attempts": 1},
            read_timeout=read_timeout,
            connect_timeout=5,
        ),
    )


@pytest.fixture
def sqs():
    return _make_sqs()


def _unique(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


@pytest.fixture
def queue_url(sqs):
    name = _unique("batch")
    url = sqs.create_queue(QueueName=name)["QueueUrl"]
    yield url
    try:
        sqs.delete_queue(QueueUrl=url)
    except botocore.exceptions.ClientError:
        pass


# ---------------------------------------------------------------------------
# SendMessageBatch


def test_send_batch_all_successful(sqs, queue_url):
    entries = [
        {"Id": f"e{i}", "MessageBody": f"body-{i}"} for i in range(5)
    ]
    out = sqs.send_message_batch(QueueUrl=queue_url, Entries=entries)
    assert len(out["Successful"]) == 5
    assert out.get("Failed", []) == []
    # Verify each successful entry carries MessageId + MD5.
    for s in out["Successful"]:
        assert "MessageId" in s
        assert "MD5OfMessageBody" in s


def test_send_batch_messages_receivable(sqs, queue_url):
    sqs.send_message_batch(QueueUrl=queue_url, Entries=[
        {"Id": "a", "MessageBody": "alpha"},
        {"Id": "b", "MessageBody": "beta"},
    ])
    received = []
    for _ in range(5):
        out = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=10, VisibilityTimeout=0)
        for m in out.get("Messages", []):
            received.append(m["Body"])
        if len(received) >= 2:
            break
    assert sorted(received[:2]) == ["alpha", "beta"]


# ---------------------------------------------------------------------------
# DeleteMessageBatch


def test_delete_batch_mixed_success_and_failure(sqs, queue_url):
    sqs.send_message(QueueUrl=queue_url, MessageBody="x")
    out = sqs.receive_message(QueueUrl=queue_url)
    real_handle = out["Messages"][0]["ReceiptHandle"]
    res = sqs.delete_message_batch(QueueUrl=queue_url, Entries=[
        {"Id": "ok", "ReceiptHandle": real_handle},
        {"Id": "bad", "ReceiptHandle": "not-a-real-handle-padding-padding"},
    ])
    success_ids = {s["Id"] for s in res["Successful"]}
    failed_ids = {f["Id"] for f in res["Failed"]}
    assert "ok" in success_ids
    assert "bad" in failed_ids


# ---------------------------------------------------------------------------
# ChangeMessageVisibilityBatch


def test_change_visibility_batch(sqs, queue_url):
    sqs.send_message(QueueUrl=queue_url, MessageBody="m1")
    sqs.send_message(QueueUrl=queue_url, MessageBody="m2")
    out = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=10)
    handles = [m["ReceiptHandle"] for m in out["Messages"]]
    res = sqs.change_message_visibility_batch(QueueUrl=queue_url, Entries=[
        {"Id": "e0", "ReceiptHandle": handles[0], "VisibilityTimeout": 0},
        {"Id": "e1", "ReceiptHandle": handles[1], "VisibilityTimeout": 0},
    ])
    assert len(res["Successful"]) == 2
    # Both should be receivable again since VT=0.
    rcv = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=10)
    assert len(rcv["Messages"]) == 2


# ---------------------------------------------------------------------------
# Long polling


def test_long_poll_returns_empty_after_wait(sqs, queue_url):
    """With no messages + WaitTimeSeconds=1, ReceiveMessage waits ~1s
    then returns empty."""
    start = time.time()
    out = sqs.receive_message(QueueUrl=queue_url, WaitTimeSeconds=1)
    elapsed = time.time() - start
    assert "Messages" not in out or out["Messages"] == []
    # Should have waited at least ~0.8s (allow some skew).
    assert elapsed >= 0.8, f"long-poll returned in {elapsed:.2f}s, expected ≥0.8s"


def test_long_poll_wakes_up_on_send(sqs, queue_url):
    """ReceiveMessage with WaitTimeSeconds=10 returns early as soon as
    a parallel SendMessage delivers a message."""
    received: list[str] = []

    def receiver():
        c = _make_sqs(read_timeout=30)
        out = c.receive_message(QueueUrl=queue_url, WaitTimeSeconds=10)
        for m in out.get("Messages", []):
            received.append(m["Body"])

    t = threading.Thread(target=receiver)
    t.start()
    # Give the receiver a moment to start polling.
    time.sleep(0.3)
    sqs.send_message(QueueUrl=queue_url, MessageBody="wakeup")
    t.join(timeout=5)
    assert not t.is_alive(), "receiver thread did not return in time"
    assert received == ["wakeup"]
