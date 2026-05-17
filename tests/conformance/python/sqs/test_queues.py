"""SQS queue-management conformance — Phase 1 of v0.3.0.

Covers the seven queue-CRUD ops: CreateQueue, DeleteQueue, ListQueues,
GetQueueUrl, GetQueueAttributes, SetQueueAttributes, PurgeQueue. Later
phases add message + tag ops.
"""

from __future__ import annotations

import os
import socket
import subprocess
import tempfile
import time
import uuid

import boto3
import botocore.exceptions
import pytest
from botocore.config import Config

from conftest import endpoint


def _make_sqs(ep: str | None = None):
    return boto3.client(
        "sqs",
        endpoint_url=ep or endpoint(),
        region_name="us-east-1",
        aws_access_key_id="test",
        aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 1}),
    )


@pytest.fixture
def sqs():
    return _make_sqs()


def _unique_queue(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


@pytest.fixture
def created_queue(sqs):
    """Yields a callable that creates a queue and registers cleanup."""
    created: list[str] = []

    def make(name: str | None = None, attrs: dict | None = None) -> str:
        n = name or _unique_queue("q")
        kwargs = {"QueueName": n}
        if attrs is not None:
            kwargs["Attributes"] = attrs
        url = sqs.create_queue(**kwargs)["QueueUrl"]
        created.append(url)
        return url

    yield make

    for url in created:
        try:
            sqs.delete_queue(QueueUrl=url)
        except botocore.exceptions.ClientError:
            pass


# ---------------------------------------------------------------------------
# CreateQueue


def test_create_queue_returns_url(created_queue):
    url = created_queue()
    # Queue URL shape: http://<host>:<port>/<account>/<name>
    assert "/000000000000/" in url


def test_create_queue_idempotent_on_same_name(sqs, created_queue):
    name = _unique_queue("idem")
    url1 = created_queue(name=name)
    # Second call returns the same URL.
    url2 = sqs.create_queue(QueueName=name)["QueueUrl"]
    assert url1 == url2


def test_create_queue_with_attributes(created_queue, sqs):
    url = created_queue(attrs={"VisibilityTimeout": "60", "DelaySeconds": "5"})
    attrs = sqs.get_queue_attributes(QueueUrl=url, AttributeNames=["All"])["Attributes"]
    assert attrs["VisibilityTimeout"] == "60"
    assert attrs["DelaySeconds"] == "5"


def test_create_queue_rejects_bad_name(sqs):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        sqs.create_queue(QueueName="has space")
    code = ei.value.response["Error"]["Code"]
    # Either client-side ParamValidation or server-side InvalidParameterValue.
    assert code in ("InvalidParameterValue", "ParamValidationError")


# ---------------------------------------------------------------------------
# ListQueues


def test_list_queues_includes_recent(sqs, created_queue):
    url = created_queue()
    urls = sqs.list_queues().get("QueueUrls", [])
    assert url in urls


def test_list_queues_filters_by_prefix(sqs, created_queue):
    a = _unique_queue("alpha")
    b = _unique_queue("beta")
    created_queue(name=a)
    created_queue(name=b)
    out = sqs.list_queues(QueueNamePrefix="alpha").get("QueueUrls", [])
    assert any(a in u for u in out)
    assert not any(b in u for u in out)


# ---------------------------------------------------------------------------
# GetQueueUrl


def test_get_queue_url(sqs, created_queue):
    name = _unique_queue("gqu")
    url = created_queue(name=name)
    got = sqs.get_queue_url(QueueName=name)["QueueUrl"]
    assert got == url


def test_get_queue_url_missing_returns_not_found(sqs):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        sqs.get_queue_url(QueueName=_unique_queue("nope"))
    assert ei.value.response["Error"]["Code"] == "AWS.SimpleQueueService.NonExistentQueue"


# ---------------------------------------------------------------------------
# GetQueueAttributes / SetQueueAttributes


def test_get_queue_attributes_all(sqs, created_queue):
    url = created_queue()
    attrs = sqs.get_queue_attributes(QueueUrl=url, AttributeNames=["All"])["Attributes"]
    # Defaults match AWS-real.
    assert attrs["VisibilityTimeout"] == "30"
    assert attrs["DelaySeconds"] == "0"
    assert attrs["ReceiveMessageWaitTimeSeconds"] == "0"
    assert attrs["MaximumMessageSize"] == "262144"
    assert "QueueArn" in attrs
    assert attrs["QueueArn"].startswith("arn:aws:sqs:us-east-1:")


def test_get_queue_attributes_subset(sqs, created_queue):
    url = created_queue()
    attrs = sqs.get_queue_attributes(QueueUrl=url, AttributeNames=["VisibilityTimeout"])["Attributes"]
    assert "VisibilityTimeout" in attrs
    assert "DelaySeconds" not in attrs


def test_set_queue_attributes_round_trip(sqs, created_queue):
    url = created_queue()
    sqs.set_queue_attributes(QueueUrl=url, Attributes={"VisibilityTimeout": "120", "DelaySeconds": "10"})
    attrs = sqs.get_queue_attributes(QueueUrl=url, AttributeNames=["All"])["Attributes"]
    assert attrs["VisibilityTimeout"] == "120"
    assert attrs["DelaySeconds"] == "10"


# ---------------------------------------------------------------------------
# DeleteQueue


def test_delete_queue_removes_it(sqs, created_queue):
    url = created_queue()
    sqs.delete_queue(QueueUrl=url)
    urls = sqs.list_queues().get("QueueUrls", [])
    assert url not in urls


def test_delete_missing_queue_returns_not_found(sqs):
    fake = f"http://127.0.0.1:14566/000000000000/{_unique_queue('ghost')}"
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        sqs.delete_queue(QueueUrl=fake)
    assert ei.value.response["Error"]["Code"] == "AWS.SimpleQueueService.NonExistentQueue"


# ---------------------------------------------------------------------------
# PurgeQueue


def test_purge_empty_queue_is_noop(sqs, created_queue):
    url = created_queue()
    # Purging an empty queue should succeed (no messages to remove).
    sqs.purge_queue(QueueUrl=url)


# ---------------------------------------------------------------------------
# Persistence across restart


def _spawn_nanostack(bin_path: str, data_dir: str, port: int) -> subprocess.Popen:
    proc = subprocess.Popen(
        [bin_path, "--port", str(port), "--data-dir", data_dir, "--services", "s3,sqs"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    import requests
    deadline = time.time() + 5
    url = f"http://127.0.0.1:{port}/"
    while time.time() < deadline:
        try:
            requests.get(url, timeout=1)
            return proc
        except requests.RequestException:
            time.sleep(0.1)
    proc.kill()
    raise AssertionError(f"nanostack did not bind :{port} within 5s")


def test_queue_persists_across_restart():
    bin_path = os.environ.get("NANOSTACK_BIN")
    if not bin_path:
        pytest.skip("NANOSTACK_BIN not set; skipping restart conformance test")

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    data_dir = tempfile.mkdtemp(prefix="ns-sqs-restart-")
    ep = f"http://127.0.0.1:{port}"
    name = _unique_queue("persist")

    proc = _spawn_nanostack(bin_path, data_dir, port)
    try:
        c = _make_sqs(ep)
        c.create_queue(QueueName=name, Attributes={"VisibilityTimeout": "60"})
    finally:
        proc.kill()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass

    proc2 = _spawn_nanostack(bin_path, data_dir, port)
    try:
        c = _make_sqs(ep)
        url = c.get_queue_url(QueueName=name)["QueueUrl"]
        attrs = c.get_queue_attributes(QueueUrl=url, AttributeNames=["VisibilityTimeout"])["Attributes"]
        assert attrs["VisibilityTimeout"] == "60"
    finally:
        proc2.kill()
        try:
            proc2.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        import shutil
        shutil.rmtree(data_dir, ignore_errors=True)
