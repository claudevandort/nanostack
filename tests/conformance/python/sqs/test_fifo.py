"""SQS FIFO conformance — v0.3.1.

Phase A: FifoQueue attribute + name-suffix validation + GetQueueAttributes
round-trip. Later phases add MessageGroupId / dedup / per-group ordering.
"""

from __future__ import annotations

import os
import secrets
import socket
import subprocess
import tempfile
import time

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


def _fifo_name() -> str:
    return f"q_{secrets.token_hex(4)}.fifo"


def _std_name() -> str:
    return f"q_{secrets.token_hex(4)}"


@pytest.fixture
def sqs():
    return _make_sqs()


# ---------- Phase A — FifoQueue attribute + name validation ----------


def test_fifo_create_with_explicit_attribute(sqs):
    name = _fifo_name()
    try:
        out = sqs.create_queue(QueueName=name, Attributes={"FifoQueue": "true"})
        assert name in out["QueueUrl"]
    finally:
        sqs.delete_queue(QueueUrl=out["QueueUrl"])


def test_fifo_create_derives_from_name_suffix(sqs):
    # AWS accepts a `.fifo` name without an explicit FifoQueue attribute
    # and treats the queue as FIFO. We follow suit.
    name = _fifo_name()
    out = sqs.create_queue(QueueName=name)
    try:
        attrs = sqs.get_queue_attributes(
            QueueUrl=out["QueueUrl"], AttributeNames=["FifoQueue"]
        )["Attributes"]
        assert attrs.get("FifoQueue") == "true"
    finally:
        sqs.delete_queue(QueueUrl=out["QueueUrl"])


def test_fifo_attribute_on_non_fifo_name_rejected(sqs):
    with pytest.raises(botocore.exceptions.ClientError) as exc:
        sqs.create_queue(QueueName=_std_name(), Attributes={"FifoQueue": "true"})
    assert exc.value.response["Error"]["Code"] == "InvalidAttributeValue"


def test_fifo_name_with_false_attribute_rejected(sqs):
    with pytest.raises(botocore.exceptions.ClientError) as exc:
        sqs.create_queue(QueueName=_fifo_name(), Attributes={"FifoQueue": "false"})
    assert exc.value.response["Error"]["Code"] == "InvalidAttributeValue"


def test_set_queue_attributes_rejects_fifo_mutation(sqs):
    name = _fifo_name()
    out = sqs.create_queue(QueueName=name, Attributes={"FifoQueue": "true"})
    try:
        with pytest.raises(botocore.exceptions.ClientError) as exc:
            sqs.set_queue_attributes(
                QueueUrl=out["QueueUrl"], Attributes={"FifoQueue": "false"}
            )
        assert exc.value.response["Error"]["Code"] == "InvalidAttributeValue"
    finally:
        sqs.delete_queue(QueueUrl=out["QueueUrl"])


def test_content_based_dedup_round_trip(sqs):
    name = _fifo_name()
    out = sqs.create_queue(
        QueueName=name,
        Attributes={"FifoQueue": "true", "ContentBasedDeduplication": "true"},
    )
    try:
        attrs = sqs.get_queue_attributes(
            QueueUrl=out["QueueUrl"], AttributeNames=["ContentBasedDeduplication"]
        )["Attributes"]
        assert attrs.get("ContentBasedDeduplication") == "true"
    finally:
        sqs.delete_queue(QueueUrl=out["QueueUrl"])


def test_content_based_dedup_rejected_on_standard_queue(sqs):
    with pytest.raises(botocore.exceptions.ClientError) as exc:
        sqs.create_queue(
            QueueName=_std_name(), Attributes={"ContentBasedDeduplication": "true"}
        )
    assert exc.value.response["Error"]["Code"] == "InvalidAttributeValue"


def test_fifo_attribute_survives_restart():
    """Cold-start the server, create a FIFO queue, restart, verify is_fifo round-trips."""
    bin_path = os.environ.get("NANOSTACK_BIN")
    if not bin_path:
        pytest.skip("NANOSTACK_BIN not set")

    data_dir = tempfile.mkdtemp(prefix="ns-fifo-")
    port = _pick_port()
    ep = f"http://127.0.0.1:{port}"

    def spawn():
        return subprocess.Popen(
            [bin_path, "--port", str(port), "--data-dir", data_dir, "--services", "sqs"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    proc = spawn()
    try:
        _wait_ready(port)
        sqs = _make_sqs(ep)
        name = _fifo_name()
        sqs.create_queue(QueueName=name, Attributes={"FifoQueue": "true"})
    finally:
        proc.terminate()
        proc.wait(timeout=5)

    proc = spawn()
    try:
        _wait_ready(port)
        sqs = _make_sqs(ep)
        url = sqs.get_queue_url(QueueName=name)["QueueUrl"]
        attrs = sqs.get_queue_attributes(QueueUrl=url, AttributeNames=["FifoQueue"])[
            "Attributes"
        ]
        assert attrs.get("FifoQueue") == "true"
    finally:
        proc.terminate()
        proc.wait(timeout=5)


def _pick_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _wait_ready(port: int, timeout: float = 5.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.socket() as s:
                s.connect(("127.0.0.1", port))
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError(f"nanostack did not bind to {port}")
