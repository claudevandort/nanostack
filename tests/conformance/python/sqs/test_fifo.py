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


# ---------- Phase B — SendMessage FIFO validation + SequenceNumber ----------


@pytest.fixture
def fifo_queue(sqs):
    name = _fifo_name()
    out = sqs.create_queue(
        QueueName=name,
        Attributes={"FifoQueue": "true", "ContentBasedDeduplication": "true"},
    )
    yield name, out["QueueUrl"]
    sqs.delete_queue(QueueUrl=out["QueueUrl"])


@pytest.fixture
def std_queue(sqs):
    name = _std_name()
    out = sqs.create_queue(QueueName=name)
    yield name, out["QueueUrl"]
    sqs.delete_queue(QueueUrl=out["QueueUrl"])


def test_fifo_send_without_group_id_rejected(sqs, fifo_queue):
    _, url = fifo_queue
    with pytest.raises(botocore.exceptions.ClientError) as exc:
        sqs.send_message(QueueUrl=url, MessageBody="hi")
    assert exc.value.response["Error"]["Code"] == "MissingParameter"


def test_fifo_send_with_per_message_delay_rejected(sqs, fifo_queue):
    _, url = fifo_queue
    with pytest.raises(botocore.exceptions.ClientError) as exc:
        sqs.send_message(
            QueueUrl=url,
            MessageBody="hi",
            MessageGroupId="g1",
            DelaySeconds=5,
        )
    assert exc.value.response["Error"]["Code"] == "InvalidParameterValue"


def test_standard_send_with_group_id_rejected(sqs, std_queue):
    _, url = std_queue
    with pytest.raises(botocore.exceptions.ClientError) as exc:
        sqs.send_message(QueueUrl=url, MessageBody="hi", MessageGroupId="g1")
    assert exc.value.response["Error"]["Code"] == "InvalidParameterValue"


def test_fifo_send_returns_sequence_number(sqs, fifo_queue):
    _, url = fifo_queue
    out = sqs.send_message(QueueUrl=url, MessageBody="hi", MessageGroupId="g1")
    assert "MessageId" in out
    assert "SequenceNumber" in out
    # AWS docs say "up to 39 digits" but always a long decimal; ours is
    # zero-padded width-20 for u128. Verify it parses as an integer.
    int(out["SequenceNumber"])


def test_fifo_sequence_numbers_monotonic(sqs, fifo_queue):
    _, url = fifo_queue
    sn1 = int(
        sqs.send_message(QueueUrl=url, MessageBody="a", MessageGroupId="g1")[
            "SequenceNumber"
        ]
    )
    sn2 = int(
        sqs.send_message(QueueUrl=url, MessageBody="b", MessageGroupId="g1")[
            "SequenceNumber"
        ]
    )
    sn3 = int(
        sqs.send_message(QueueUrl=url, MessageBody="c", MessageGroupId="g2")[
            "SequenceNumber"
        ]
    )
    assert sn1 < sn2 < sn3


def test_fifo_send_without_dedup_id_or_content_dedup_rejected():
    """A FIFO queue without ContentBasedDeduplication=true requires explicit
    MessageDeduplicationId on every send."""
    sqs = _make_sqs()
    name = _fifo_name()
    out = sqs.create_queue(QueueName=name, Attributes={"FifoQueue": "true"})
    try:
        with pytest.raises(botocore.exceptions.ClientError) as exc:
            sqs.send_message(QueueUrl=out["QueueUrl"], MessageBody="hi", MessageGroupId="g1")
        assert exc.value.response["Error"]["Code"] == "InvalidParameterValue"
    finally:
        sqs.delete_queue(QueueUrl=out["QueueUrl"])


def test_fifo_send_batch_per_entry_sequence_numbers(sqs, fifo_queue):
    _, url = fifo_queue
    out = sqs.send_message_batch(
        QueueUrl=url,
        Entries=[
            {"Id": "a", "MessageBody": "a", "MessageGroupId": "g1"},
            {"Id": "b", "MessageBody": "b", "MessageGroupId": "g1"},
            {"Id": "c", "MessageBody": "c", "MessageGroupId": "g2"},
        ],
    )
    assert "Failed" not in out or len(out["Failed"]) == 0
    seqs = sorted(int(e["SequenceNumber"]) for e in out["Successful"])
    assert seqs[0] < seqs[1] < seqs[2]


def test_fifo_sequence_counter_survives_restart():
    """Sequence counter is persisted on disk so re-sends after restart
    can't collide with pre-restart sequence numbers."""
    bin_path = os.environ.get("NANOSTACK_BIN")
    if not bin_path:
        pytest.skip("NANOSTACK_BIN not set")

    data_dir = tempfile.mkdtemp(prefix="ns-fifo-seq-")
    port = _pick_port()
    ep = f"http://127.0.0.1:{port}"

    def spawn():
        return subprocess.Popen(
            [bin_path, "--port", str(port), "--data-dir", data_dir, "--services", "sqs"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    name = _fifo_name()
    proc = spawn()
    try:
        _wait_ready(port)
        sqs = _make_sqs(ep)
        url = sqs.create_queue(
            QueueName=name,
            Attributes={"FifoQueue": "true", "ContentBasedDeduplication": "true"},
        )["QueueUrl"]
        sn1 = int(
            sqs.send_message(QueueUrl=url, MessageBody="a", MessageGroupId="g1")[
                "SequenceNumber"
            ]
        )
    finally:
        proc.terminate()
        proc.wait(timeout=5)

    proc = spawn()
    try:
        _wait_ready(port)
        sqs = _make_sqs(ep)
        url = sqs.get_queue_url(QueueName=name)["QueueUrl"]
        sn2 = int(
            sqs.send_message(QueueUrl=url, MessageBody="b", MessageGroupId="g1")[
                "SequenceNumber"
            ]
        )
        assert sn2 > sn1
    finally:
        proc.terminate()
        proc.wait(timeout=5)


# ---------- Phase C — dedup window + content-based dedup ----------


def test_fifo_explicit_dedup_id_silently_dedupes(sqs):
    """Two sends with the same MessageDeduplicationId within 5 minutes:
    the second returns the first's MessageId + SequenceNumber and is
    silently dropped."""
    name = _fifo_name()
    url = sqs.create_queue(QueueName=name, Attributes={"FifoQueue": "true"})["QueueUrl"]
    try:
        first = sqs.send_message(
            QueueUrl=url, MessageBody="a", MessageGroupId="g1",
            MessageDeduplicationId="dup-1",
        )
        second = sqs.send_message(
            QueueUrl=url, MessageBody="a-different", MessageGroupId="g1",
            MessageDeduplicationId="dup-1",
        )
        assert first["MessageId"] == second["MessageId"]
        assert first["SequenceNumber"] == second["SequenceNumber"]
        # Verify only one message is in the queue (the original).
        recv = sqs.receive_message(QueueUrl=url, MaxNumberOfMessages=10)
        assert len(recv.get("Messages", [])) == 1
        assert recv["Messages"][0]["Body"] == "a"
    finally:
        sqs.delete_queue(QueueUrl=url)


def test_fifo_content_based_dedup_uses_body_hash(sqs, fifo_queue):
    """ContentBasedDeduplication=true on the queue makes identical
    bodies dedupe even without explicit MessageDeduplicationId."""
    _, url = fifo_queue
    first = sqs.send_message(QueueUrl=url, MessageBody="payload", MessageGroupId="g1")
    second = sqs.send_message(QueueUrl=url, MessageBody="payload", MessageGroupId="g1")
    assert first["MessageId"] == second["MessageId"]


def test_fifo_different_dedup_ids_same_body_both_delivered(sqs):
    name = _fifo_name()
    url = sqs.create_queue(QueueName=name, Attributes={"FifoQueue": "true"})["QueueUrl"]
    try:
        first = sqs.send_message(
            QueueUrl=url, MessageBody="same", MessageGroupId="g1",
            MessageDeduplicationId="d1",
        )
        second = sqs.send_message(
            QueueUrl=url, MessageBody="same", MessageGroupId="g1",
            MessageDeduplicationId="d2",
        )
        assert first["MessageId"] != second["MessageId"]
    finally:
        sqs.delete_queue(QueueUrl=url)


def test_fifo_send_batch_dedupes_within_batch(sqs, fifo_queue):
    """Two batch entries with the same effective dedup id (content-hash
    fallback here) collapse to one delivered message."""
    _, url = fifo_queue
    out = sqs.send_message_batch(
        QueueUrl=url,
        Entries=[
            {"Id": "a", "MessageBody": "batch-payload", "MessageGroupId": "g1"},
            {"Id": "b", "MessageBody": "batch-payload", "MessageGroupId": "g1"},
        ],
    )
    successful = {e["Id"]: e for e in out["Successful"]}
    # Both entries succeed individually, but they reference the same
    # underlying MessageId.
    assert successful["a"]["MessageId"] == successful["b"]["MessageId"]


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
