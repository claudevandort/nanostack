"""SQS via `aws sqs` v2 CLI (v0.3.0)."""

from __future__ import annotations

import json
import secrets

import pytest

from conftest import run_aws


@pytest.fixture
def queue():
    name = f"cli_q_{secrets.token_hex(4)}"
    out = run_aws("sqs", "create-queue", "--queue-name", name, json_output=True).json()
    url = out["QueueUrl"]
    yield name, url
    run_aws("sqs", "delete-queue", "--queue-url", url, check=False)


def test_create_and_list_queue(queue):
    name, url = queue
    out = run_aws("sqs", "list-queues", json_output=True).json()
    assert url in out["QueueUrls"]


def test_get_queue_attributes(queue):
    _, url = queue
    out = run_aws(
        "sqs", "get-queue-attributes",
        "--queue-url", url,
        "--attribute-names", "All",
        json_output=True,
    ).json()
    assert out["Attributes"]["VisibilityTimeout"] == "30"


def test_send_and_receive_message(queue):
    _, url = queue
    send = run_aws(
        "sqs", "send-message",
        "--queue-url", url,
        "--message-body", "hello-from-cli",
        json_output=True,
    ).json()
    assert "MessageId" in send

    recv = run_aws(
        "sqs", "receive-message",
        "--queue-url", url,
        json_output=True,
    ).json()
    assert recv["Messages"][0]["Body"] == "hello-from-cli"


def test_send_receive_delete_round_trip(queue):
    _, url = queue
    run_aws("sqs", "send-message", "--queue-url", url, "--message-body", "x")
    recv = run_aws("sqs", "receive-message", "--queue-url", url, json_output=True).json()
    handle = recv["Messages"][0]["ReceiptHandle"]
    run_aws("sqs", "delete-message", "--queue-url", url, "--receipt-handle", handle)
    # After delete + VT=0 receive, queue is empty.
    # The CLI prints an empty body when there are no messages, so
    # avoid `json_output` (which would try to JSON-parse "").
    out_result = run_aws(
        "sqs", "receive-message",
        "--queue-url", url,
        "--visibility-timeout", "0",
    )
    # Empty stdout means no messages — AWS CLI's convention.
    assert out_result.stdout.strip() == "" or "Messages" not in json.loads(out_result.stdout)
