"""SNS robustness via `aws sns` v2 CLI (v0.4.1)."""

from __future__ import annotations

import json
import secrets
import time

import pytest

from conftest import run_aws


def test_cli_add_permission_round_trip():
    name = f"cli_t_{secrets.token_hex(4)}"
    arn = run_aws("sns", "create-topic", "--name", name, json_output=True).json()["TopicArn"]
    try:
        run_aws(
            "sns", "add-permission",
            "--topic-arn", arn,
            "--label", "grant1",
            "--aws-account-id", "111122223333",
            "--action-name", "Publish",
        )
        out = run_aws(
            "sns", "get-topic-attributes",
            "--topic-arn", arn,
            json_output=True,
        ).json()
        policy = out["Attributes"]["Policy"]
        assert "grant1" in policy
        assert "sns:Publish" in policy
        # Remove and verify.
        run_aws(
            "sns", "remove-permission",
            "--topic-arn", arn,
            "--label", "grant1",
        )
        out2 = run_aws(
            "sns", "get-topic-attributes",
            "--topic-arn", arn,
            json_output=True,
        ).json()
        assert "Policy" not in out2.get("Attributes", {}) or not out2["Attributes"].get("Policy")
    finally:
        run_aws("sns", "delete-topic", "--topic-arn", arn, check=False)


def test_cli_filter_policy_gates_delivery():
    tname = f"cli_t_{secrets.token_hex(4)}"
    qname = f"cli_q_{secrets.token_hex(4)}"
    topic_arn = run_aws("sns", "create-topic", "--name", tname, json_output=True).json()["TopicArn"]
    qurl = run_aws("sqs", "create-queue", "--queue-name", qname, json_output=True).json()["QueueUrl"]
    try:
        sub_arn = run_aws(
            "sns", "subscribe",
            "--topic-arn", topic_arn,
            "--protocol", "sqs",
            "--notification-endpoint", f"arn:aws:sqs:us-east-1:000000000000:{qname}",
            json_output=True,
        ).json()["SubscriptionArn"]
        run_aws(
            "sns", "set-subscription-attributes",
            "--subscription-arn", sub_arn,
            "--attribute-name", "FilterPolicy",
            "--attribute-value", json.dumps({"category": ["news"]}),
        )
        # Non-matching → filtered.
        run_aws(
            "sns", "publish",
            "--topic-arn", topic_arn,
            "--message", "filtered",
            "--message-attributes",
            json.dumps({"category": {"DataType": "String", "StringValue": "sports"}}),
        )
        # Matching → delivered.
        run_aws(
            "sns", "publish",
            "--topic-arn", topic_arn,
            "--message", "delivered",
            "--message-attributes",
            json.dumps({"category": {"DataType": "String", "StringValue": "news"}}),
        )
        time.sleep(0.5)
        out = run_aws(
            "sqs", "receive-message",
            "--queue-url", qurl,
            "--max-number-of-messages", "10",
            "--wait-time-seconds", "2",
            json_output=True,
        )
        assert out.stdout.strip(), "expected at least one message"
        msgs = json.loads(out.stdout).get("Messages", [])
        assert len(msgs) == 1
        env = json.loads(msgs[0]["Body"])
        assert env["Message"] == "delivered"
    finally:
        run_aws("sns", "delete-topic", "--topic-arn", topic_arn, check=False)
        run_aws("sqs", "delete-queue", "--queue-url", qurl, check=False)
