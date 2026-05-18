"""SNS via `aws sns` v2 CLI (v0.4.0)."""

from __future__ import annotations

import json
import secrets
import time

import pytest

from conftest import run_aws


def test_cli_create_and_list_topic():
    name = f"cli_t_{secrets.token_hex(4)}"
    out = run_aws("sns", "create-topic", "--name", name, json_output=True).json()
    arn = out["TopicArn"]
    try:
        listed = run_aws("sns", "list-topics", json_output=True).json()
        arns = [t["TopicArn"] for t in listed["Topics"]]
        assert arn in arns
    finally:
        run_aws("sns", "delete-topic", "--topic-arn", arn, check=False)


def test_cli_subscribe_returns_sub_arn():
    tname = f"cli_t_{secrets.token_hex(4)}"
    qname = f"cli_q_{secrets.token_hex(4)}"
    topic_arn = run_aws("sns", "create-topic", "--name", tname, json_output=True).json()["TopicArn"]
    qurl = run_aws("sqs", "create-queue", "--queue-name", qname, json_output=True).json()["QueueUrl"]
    try:
        out = run_aws(
            "sns", "subscribe",
            "--topic-arn", topic_arn,
            "--protocol", "sqs",
            "--notification-endpoint", f"arn:aws:sqs:us-east-1:000000000000:{qname}",
            json_output=True,
        ).json()
        assert out["SubscriptionArn"].startswith("arn:aws:sns:")
    finally:
        run_aws("sns", "delete-topic", "--topic-arn", topic_arn, check=False)
        run_aws("sqs", "delete-queue", "--queue-url", qurl, check=False)


def test_cli_publish_delivers_to_sqs():
    tname = f"cli_t_{secrets.token_hex(4)}"
    qname = f"cli_q_{secrets.token_hex(4)}"
    topic_arn = run_aws("sns", "create-topic", "--name", tname, json_output=True).json()["TopicArn"]
    qurl = run_aws("sqs", "create-queue", "--queue-name", qname, json_output=True).json()["QueueUrl"]
    try:
        run_aws(
            "sns", "subscribe",
            "--topic-arn", topic_arn,
            "--protocol", "sqs",
            "--notification-endpoint", f"arn:aws:sqs:us-east-1:000000000000:{qname}",
        )
        run_aws(
            "sns", "publish",
            "--topic-arn", topic_arn,
            "--message", "hello-cli",
        )
        time.sleep(0.5)
        out = run_aws(
            "sqs", "receive-message",
            "--queue-url", qurl,
            "--wait-time-seconds", "2",
            json_output=True,
        )
        assert out.stdout.strip(), "expected message"
        msgs = json.loads(out.stdout)["Messages"]
        body = json.loads(msgs[0]["Body"])
        assert body["Type"] == "Notification"
        assert body["Message"] == "hello-cli"
    finally:
        run_aws("sns", "delete-topic", "--topic-arn", topic_arn, check=False)
        run_aws("sqs", "delete-queue", "--queue-url", qurl, check=False)


def test_cli_tag_resource_round_trip():
    name = f"cli_t_{secrets.token_hex(4)}"
    arn = run_aws("sns", "create-topic", "--name", name, json_output=True).json()["TopicArn"]
    try:
        run_aws(
            "sns", "tag-resource",
            "--resource-arn", arn,
            "--tags", "Key=env,Value=dev",
        )
        out = run_aws(
            "sns", "list-tags-for-resource",
            "--resource-arn", arn,
            json_output=True,
        ).json()
        tags = {t["Key"]: t["Value"] for t in out["Tags"]}
        assert tags == {"env": "dev"}
    finally:
        run_aws("sns", "delete-topic", "--topic-arn", arn, check=False)
