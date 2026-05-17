"""SQS FIFO via `aws sqs` v2 CLI (v0.3.1)."""

from __future__ import annotations

import secrets

import pytest

from conftest import run_aws


@pytest.fixture
def fifo_queue():
    name = f"cli_fifo_{secrets.token_hex(4)}.fifo"
    out = run_aws(
        "sqs", "create-queue",
        "--queue-name", name,
        "--attributes", "FifoQueue=true,ContentBasedDeduplication=true",
        json_output=True,
    ).json()
    url = out["QueueUrl"]
    yield name, url
    run_aws("sqs", "delete-queue", "--queue-url", url, check=False)


def test_cli_fifo_create_and_attributes(fifo_queue):
    _, url = fifo_queue
    out = run_aws(
        "sqs", "get-queue-attributes",
        "--queue-url", url,
        "--attribute-names", "FifoQueue", "ContentBasedDeduplication",
        json_output=True,
    ).json()
    assert out["Attributes"]["FifoQueue"] == "true"
    assert out["Attributes"]["ContentBasedDeduplication"] == "true"


def test_cli_fifo_send_returns_sequence_number(fifo_queue):
    _, url = fifo_queue
    out = run_aws(
        "sqs", "send-message",
        "--queue-url", url,
        "--message-body", "hello",
        "--message-group-id", "g1",
        json_output=True,
    ).json()
    assert "MessageId" in out
    assert "SequenceNumber" in out
    int(out["SequenceNumber"])  # parses as integer


def test_cli_fifo_head_of_line_ordering(fifo_queue):
    _, url = fifo_queue
    for body in ["a", "b", "c"]:
        run_aws(
            "sqs", "send-message",
            "--queue-url", url,
            "--message-body", body,
            "--message-group-id", "g1",
        )
    out = run_aws(
        "sqs", "receive-message",
        "--queue-url", url,
        "--max-number-of-messages", "10",
        json_output=True,
    ).json()
    # Only the head is delivered until the in-flight message is deleted.
    assert len(out["Messages"]) == 1
    assert out["Messages"][0]["Body"] == "a"
