"""SQS Queue Policy enforcement via `aws sqs` v2 CLI (v0.3.3)."""

from __future__ import annotations

import json
import secrets

import pytest

from conftest import run_aws


def _owner_deny_policy(queue_name: str) -> str:
    return json.dumps({
        "Version": "2012-10-17",
        "Statement": [{
            "Sid": "DenyAll",
            "Effect": "Deny",
            "Principal": "*",
            "Action": "*",
            "Resource": f"arn:aws:sqs:us-east-1:000000000000:{queue_name}",
        }],
    })


def test_cli_owner_signed_send_works_with_no_policy():
    """Sanity: signed CLI request with the configured access_key
    succeeds against a queue with no policy (owner-implicit-allow)."""
    name = f"cli_q_{secrets.token_hex(4)}"
    url = run_aws(
        "sqs", "create-queue", "--queue-name", name, json_output=True
    ).json()["QueueUrl"]
    try:
        out = run_aws(
            "sqs", "send-message",
            "--queue-url", url,
            "--message-body", "owner-signed",
            json_output=True,
        ).json()
        assert "MessageId" in out
    finally:
        run_aws("sqs", "delete-queue", "--queue-url", url, check=False)


def test_cli_owner_bypasses_deny_all_policy():
    """Even with a `Deny *` policy attached, the queue owner can still
    operate (owner-implicit-allow short-circuits policy evaluation)."""
    name = f"cli_q_{secrets.token_hex(4)}"
    url = run_aws(
        "sqs", "create-queue", "--queue-name", name, json_output=True
    ).json()["QueueUrl"]
    try:
        run_aws(
            "sqs", "set-queue-attributes",
            "--queue-url", url,
            "--attributes", json.dumps({"Policy": _owner_deny_policy(name)}),
        )
        out = run_aws(
            "sqs", "send-message",
            "--queue-url", url,
            "--message-body", "bypass",
            json_output=True,
        ).json()
        assert "MessageId" in out
    finally:
        run_aws("sqs", "delete-queue", "--queue-url", url, check=False)
