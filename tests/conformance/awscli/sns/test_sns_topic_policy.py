"""SNS Topic Policy enforcement via `aws sns` v2 CLI (v0.4.2).

Unique basename (`test_sns_topic_policy.py`) to avoid the awscli-suite
pytest module-name collision documented after v0.4.1.
"""

from __future__ import annotations

import json
import secrets

import pytest

from conftest import run_aws


def _owner_deny_policy(topic_name: str) -> str:
    return json.dumps({
        "Version": "2012-10-17",
        "Statement": [{
            "Sid": "DenyAll",
            "Effect": "Deny",
            "Principal": "*",
            "Action": "*",
            "Resource": f"arn:aws:sns:us-east-1:000000000000:{topic_name}",
        }],
    })


def test_cli_owner_signed_publish_works_with_no_policy():
    """Sanity: signed CLI publish succeeds against a topic with no
    policy (owner-implicit-allow)."""
    name = f"cli_t_{secrets.token_hex(4)}"
    arn = run_aws(
        "sns", "create-topic", "--name", name, json_output=True
    ).json()["TopicArn"]
    try:
        out = run_aws(
            "sns", "publish",
            "--topic-arn", arn,
            "--message", "owner-signed",
            json_output=True,
        ).json()
        assert "MessageId" in out
    finally:
        run_aws("sns", "delete-topic", "--topic-arn", arn, check=False)


def test_cli_owner_bypasses_deny_all_policy():
    """Owner can publish even when the topic carries a Deny * policy."""
    name = f"cli_t_{secrets.token_hex(4)}"
    arn = run_aws(
        "sns", "create-topic", "--name", name, json_output=True
    ).json()["TopicArn"]
    try:
        run_aws(
            "sns", "set-topic-attributes",
            "--topic-arn", arn,
            "--attribute-name", "Policy",
            "--attribute-value", _owner_deny_policy(name),
        )
        out = run_aws(
            "sns", "publish",
            "--topic-arn", arn,
            "--message", "bypass",
            json_output=True,
        ).json()
        assert "MessageId" in out
    finally:
        run_aws("sns", "delete-topic", "--topic-arn", arn, check=False)
