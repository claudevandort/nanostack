"""SQS robustness via `aws sqs` v2 CLI (v0.3.2)."""

from __future__ import annotations

import json
import secrets

import pytest

from conftest import run_aws


@pytest.fixture
def queue_pair():
    """Create a source + DLQ + wire RedrivePolicy. Return (src_url,
    dlq_url, dlq_arn)."""
    dlq_name = f"cli_dlq_{secrets.token_hex(4)}"
    dlq_out = run_aws(
        "sqs", "create-queue", "--queue-name", dlq_name, json_output=True
    ).json()
    src_name = f"cli_src_{secrets.token_hex(4)}"
    src_out = run_aws(
        "sqs", "create-queue", "--queue-name", src_name, json_output=True
    ).json()
    dlq_arn = f"arn:aws:sqs:us-east-1:000000000000:{dlq_name}"
    run_aws(
        "sqs", "set-queue-attributes",
        "--queue-url", src_out["QueueUrl"],
        "--attributes",
        json.dumps({"RedrivePolicy": json.dumps({"deadLetterTargetArn": dlq_arn, "maxReceiveCount": 1})}),
    )
    yield src_out["QueueUrl"], dlq_out["QueueUrl"], dlq_arn
    run_aws("sqs", "delete-queue", "--queue-url", src_out["QueueUrl"], check=False)
    run_aws("sqs", "delete-queue", "--queue-url", dlq_out["QueueUrl"], check=False)


def test_cli_list_dead_letter_source_queues(queue_pair):
    src_url, dlq_url, _ = queue_pair
    out = run_aws(
        "sqs", "list-dead-letter-source-queues",
        "--queue-url", dlq_url,
        json_output=True,
    ).json()
    assert out["queueUrls"] == [src_url]


def test_cli_add_remove_permission():
    name = f"cli_q_{secrets.token_hex(4)}"
    url = run_aws(
        "sqs", "create-queue", "--queue-name", name, json_output=True
    ).json()["QueueUrl"]
    try:
        run_aws(
            "sqs", "add-permission",
            "--queue-url", url,
            "--label", "grant1",
            "--aws-account-ids", "111122223333",
            "--actions", "SendMessage",
        )
        attrs = run_aws(
            "sqs", "get-queue-attributes",
            "--queue-url", url,
            "--attribute-names", "Policy",
            json_output=True,
        ).json()
        assert "grant1" in attrs["Attributes"]["Policy"]
        run_aws(
            "sqs", "remove-permission",
            "--queue-url", url,
            "--label", "grant1",
        )
        attrs2 = run_aws(
            "sqs", "get-queue-attributes",
            "--queue-url", url,
            "--attribute-names", "Policy",
            json_output=True,
        ).json()
        # Policy is gone entirely after the only statement is removed.
        assert "Policy" not in attrs2.get("Attributes", {})
    finally:
        run_aws("sqs", "delete-queue", "--queue-url", url, check=False)


def test_cli_start_message_move_task(queue_pair):
    src_url, _, dlq_arn = queue_pair
    # Send + over-receive to push messages to DLQ.
    run_aws("sqs", "send-message", "--queue-url", src_url, "--message-body", "x")
    run_aws("sqs", "receive-message", "--queue-url", src_url, "--visibility-timeout", "0")
    run_aws("sqs", "receive-message", "--queue-url", src_url, "--visibility-timeout", "0")
    # Start the move task.
    start = run_aws(
        "sqs", "start-message-move-task",
        "--source-arn", dlq_arn,
        json_output=True,
    ).json()
    assert "TaskHandle" in start
    # Verify list shows the task as COMPLETED.
    out = run_aws(
        "sqs", "list-message-move-tasks",
        "--source-arn", dlq_arn,
        json_output=True,
    ).json()
    assert len(out["Results"]) == 1
    assert out["Results"][0]["Status"] == "COMPLETED"
