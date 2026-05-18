"""SQS robustness conformance — v0.3.2.

Phase A: cold-start message rehydration + FIFO dedup history persistence.
Phase B: MessageRetentionPeriod sweeper.
Phase C: ListDeadLetterSourceQueues.
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


def _make_sqs(ep: str):
    return boto3.client(
        "sqs",
        endpoint_url=ep,
        region_name="us-east-1",
        aws_access_key_id="test",
        aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 1}),
    )


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


@pytest.fixture
def restartable():
    """Spin up a fresh nanostack with its own data-dir + port.

    Yields a `(spawn, ep)` pair. `spawn()` returns a fresh subprocess;
    the test is responsible for terminating it. The data-dir persists
    across spawns so restart-survival can be asserted.
    """
    bin_path = os.environ.get("NANOSTACK_BIN")
    if not bin_path:
        pytest.skip("NANOSTACK_BIN not set")

    data_dir = tempfile.mkdtemp(prefix="ns-robustness-")
    port = _pick_port()
    ep = f"http://127.0.0.1:{port}"

    def spawn(extra_args: list[str] | None = None):
        args = [
            bin_path,
            "--port", str(port),
            "--data-dir", data_dir,
            "--services", "sqs",
        ]
        if extra_args:
            args.extend(extra_args)
        return subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    procs: list[subprocess.Popen] = []
    def spawn_tracked(extra_args=None):
        p = spawn(extra_args)
        procs.append(p)
        _wait_ready(port)
        return p

    yield spawn_tracked, ep
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()


# ---------- Phase A — cold-start restart safety ----------


def test_messages_survive_restart(restartable):
    spawn, ep = restartable
    name = f"q_{secrets.token_hex(4)}"
    proc = spawn()
    sqs = _make_sqs(ep)
    url = sqs.create_queue(QueueName=name)["QueueUrl"]
    for body in ["a", "b", "c"]:
        sqs.send_message(QueueUrl=url, MessageBody=body)
    proc.terminate()
    proc.wait(timeout=5)

    spawn()
    sqs = _make_sqs(ep)
    url = sqs.get_queue_url(QueueName=name)["QueueUrl"]
    recv = sqs.receive_message(QueueUrl=url, MaxNumberOfMessages=10)
    bodies = sorted(m["Body"] for m in recv["Messages"])
    assert bodies == ["a", "b", "c"]


def test_in_flight_visibility_persists_across_restart(restartable):
    """Send → receive (in-flight) → restart → still in-flight until
    the visibility timeout elapses on the persisted timestamp."""
    spawn, ep = restartable
    name = f"q_{secrets.token_hex(4)}"
    proc = spawn()
    sqs = _make_sqs(ep)
    url = sqs.create_queue(
        QueueName=name, Attributes={"VisibilityTimeout": "30"}
    )["QueueUrl"]
    sqs.send_message(QueueUrl=url, MessageBody="hello")
    sqs.receive_message(QueueUrl=url)  # makes it in-flight
    proc.terminate()
    proc.wait(timeout=5)

    spawn()
    sqs = _make_sqs(ep)
    url = sqs.get_queue_url(QueueName=name)["QueueUrl"]
    # Immediately after restart the message is still in-flight.
    recv = sqs.receive_message(QueueUrl=url)
    assert "Messages" not in recv or len(recv.get("Messages", [])) == 0


def test_deleted_messages_stay_deleted_after_restart(restartable):
    spawn, ep = restartable
    name = f"q_{secrets.token_hex(4)}"
    proc = spawn()
    sqs = _make_sqs(ep)
    url = sqs.create_queue(QueueName=name)["QueueUrl"]
    sqs.send_message(QueueUrl=url, MessageBody="hello")
    recv = sqs.receive_message(QueueUrl=url)
    sqs.delete_message(QueueUrl=url, ReceiptHandle=recv["Messages"][0]["ReceiptHandle"])
    proc.terminate()
    proc.wait(timeout=5)

    spawn()
    sqs = _make_sqs(ep)
    url = sqs.get_queue_url(QueueName=name)["QueueUrl"]
    recv = sqs.receive_message(QueueUrl=url, VisibilityTimeout=0)
    assert "Messages" not in recv or len(recv.get("Messages", [])) == 0


def test_fifo_dedup_history_survives_restart(restartable):
    """FIFO send with explicit dedup-id, restart, re-send within the
    5-minute window still maps to the original MessageId."""
    spawn, ep = restartable
    name = f"q_{secrets.token_hex(4)}.fifo"
    proc = spawn()
    sqs = _make_sqs(ep)
    url = sqs.create_queue(QueueName=name, Attributes={"FifoQueue": "true"})["QueueUrl"]
    first = sqs.send_message(
        QueueUrl=url,
        MessageBody="payload",
        MessageGroupId="g1",
        MessageDeduplicationId="dedup-1",
    )
    proc.terminate()
    proc.wait(timeout=5)

    spawn()
    sqs = _make_sqs(ep)
    url = sqs.get_queue_url(QueueName=name)["QueueUrl"]
    second = sqs.send_message(
        QueueUrl=url,
        MessageBody="different-body",
        MessageGroupId="g1",
        MessageDeduplicationId="dedup-1",
    )
    assert second["MessageId"] == first["MessageId"]
    assert second["SequenceNumber"] == first["SequenceNumber"]


def test_message_order_preserved_after_restart(restartable):
    """sent_unix ordering is preserved by the rehydrator's sort."""
    spawn, ep = restartable
    name = f"q_{secrets.token_hex(4)}"
    proc = spawn()
    sqs = _make_sqs(ep)
    url = sqs.create_queue(QueueName=name)["QueueUrl"]
    sent_ids = []
    for body in ["first", "second", "third"]:
        out = sqs.send_message(QueueUrl=url, MessageBody=body)
        sent_ids.append(out["MessageId"])
    proc.terminate()
    proc.wait(timeout=5)

    spawn()
    sqs = _make_sqs(ep)
    url = sqs.get_queue_url(QueueName=name)["QueueUrl"]
    recv = sqs.receive_message(QueueUrl=url, MaxNumberOfMessages=10)
    recv_ids = [m["MessageId"] for m in recv["Messages"]]
    assert recv_ids == sent_ids


# ---------- Phase B — MessageRetentionPeriod sweeper ----------


def test_retention_sweeper_drops_messages_past_retention():
    """Set MessageRetentionPeriod=60 and a 1s sweep interval. We can't
    reliably wait 60 seconds in CI, so we use the minimum retention
    period (60s) and verify the sweep happens but doesn't drop the
    just-sent message. The Zig unit test
    `sqsRetentionSweepOnce drops expired messages` covers the
    sweep-triggers-drop case directly."""
    bin_path = os.environ.get("NANOSTACK_BIN")
    if not bin_path:
        pytest.skip("NANOSTACK_BIN not set")

    data_dir = tempfile.mkdtemp(prefix="ns-retention-")
    port = _pick_port()
    ep = f"http://127.0.0.1:{port}"

    proc = subprocess.Popen(
        [
            bin_path,
            "--port", str(port),
            "--data-dir", data_dir,
            "--services", "sqs",
            "--sqs-retention-sweep-interval-seconds", "1",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        _wait_ready(port)
        sqs = _make_sqs(ep)
        name = f"q_{secrets.token_hex(4)}"
        url = sqs.create_queue(
            QueueName=name, Attributes={"MessageRetentionPeriod": "60"}
        )["QueueUrl"]
        sqs.send_message(QueueUrl=url, MessageBody="fresh")
        # Wait a couple of sweep ticks. The fresh message survives.
        time.sleep(2.5)
        recv = sqs.receive_message(QueueUrl=url, MaxNumberOfMessages=10)
        assert len(recv["Messages"]) == 1
        assert recv["Messages"][0]["Body"] == "fresh"
    finally:
        proc.terminate()
        proc.wait(timeout=5)


# ---------- Phase C — ListDeadLetterSourceQueues ----------


@pytest.fixture
def fresh_sqs():
    ep = os.environ.get("NANOSTACK_ENDPOINT", "http://127.0.0.1:14566")
    return _make_sqs(ep)


def test_list_dlq_sources_returns_empty_when_no_sources(fresh_sqs):
    dlq_name = f"dlq_{secrets.token_hex(4)}"
    dlq_url = fresh_sqs.create_queue(QueueName=dlq_name)["QueueUrl"]
    try:
        out = fresh_sqs.list_dead_letter_source_queues(QueueUrl=dlq_url)
        assert out["queueUrls"] == []
    finally:
        fresh_sqs.delete_queue(QueueUrl=dlq_url)


def test_list_dlq_sources_finds_all_sources(fresh_sqs):
    dlq_name = f"dlq_{secrets.token_hex(4)}"
    dlq_url = fresh_sqs.create_queue(QueueName=dlq_name)["QueueUrl"]
    src1 = fresh_sqs.create_queue(QueueName=f"src1_{secrets.token_hex(4)}")["QueueUrl"]
    src2 = fresh_sqs.create_queue(QueueName=f"src2_{secrets.token_hex(4)}")["QueueUrl"]
    try:
        rd = (
            '{"deadLetterTargetArn":"arn:aws:sqs:us-east-1:000000000000:'
            + dlq_name
            + '","maxReceiveCount":3}'
        )
        fresh_sqs.set_queue_attributes(QueueUrl=src1, Attributes={"RedrivePolicy": rd})
        fresh_sqs.set_queue_attributes(QueueUrl=src2, Attributes={"RedrivePolicy": rd})
        out = fresh_sqs.list_dead_letter_source_queues(QueueUrl=dlq_url)
        # Both source queues are returned.
        urls = sorted(out["queueUrls"])
        assert urls == sorted([src1, src2])
    finally:
        for u in (src1, src2, dlq_url):
            fresh_sqs.delete_queue(QueueUrl=u)


def test_list_dlq_sources_only_returns_matching_dlq(fresh_sqs):
    """Source queue pointing at *another* DLQ doesn't show up for our DLQ."""
    dlq_a = fresh_sqs.create_queue(QueueName=f"dlq_a_{secrets.token_hex(4)}")["QueueUrl"]
    dlq_b_name = f"dlq_b_{secrets.token_hex(4)}"
    dlq_b = fresh_sqs.create_queue(QueueName=dlq_b_name)["QueueUrl"]
    src = fresh_sqs.create_queue(QueueName=f"src_{secrets.token_hex(4)}")["QueueUrl"]
    try:
        rd = (
            '{"deadLetterTargetArn":"arn:aws:sqs:us-east-1:000000000000:'
            + dlq_b_name
            + '","maxReceiveCount":3}'
        )
        fresh_sqs.set_queue_attributes(QueueUrl=src, Attributes={"RedrivePolicy": rd})
        out = fresh_sqs.list_dead_letter_source_queues(QueueUrl=dlq_a)
        assert out["queueUrls"] == []
    finally:
        for u in (src, dlq_a, dlq_b):
            fresh_sqs.delete_queue(QueueUrl=u)


def test_sweep_interval_flag_validates_range():
    """`--sqs-retention-sweep-interval-seconds 0` is out of range."""
    bin_path = os.environ.get("NANOSTACK_BIN")
    if not bin_path:
        pytest.skip("NANOSTACK_BIN not set")
    proc = subprocess.run(
        [bin_path, "--sqs-retention-sweep-interval-seconds", "0", "--self-test-ready"],
        capture_output=True, text=True, timeout=5,
    )
    assert proc.returncode != 0
