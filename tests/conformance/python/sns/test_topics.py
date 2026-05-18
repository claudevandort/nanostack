"""SNS topic CRUD conformance — Phase B of v0.4.0.

Covers CreateTopic / DeleteTopic / ListTopics / GetTopicAttributes /
SetTopicAttributes. Later phases (C/D/E) add subscriptions, publish,
tags.
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


def _make_sns(ep: str | None = None):
    return boto3.client(
        "sns",
        endpoint_url=ep or endpoint(),
        region_name="us-east-1",
        aws_access_key_id="test",
        aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 1}),
    )


@pytest.fixture
def sns():
    return _make_sns()


def _name() -> str:
    return f"t_{secrets.token_hex(4)}"


def test_create_topic_returns_arn(sns):
    name = _name()
    out = sns.create_topic(Name=name)
    try:
        assert out["TopicArn"] == f"arn:aws:sns:us-east-1:000000000000:{name}"
    finally:
        sns.delete_topic(TopicArn=out["TopicArn"])


def test_create_topic_idempotent_on_same_name(sns):
    name = _name()
    a = sns.create_topic(Name=name)
    b = sns.create_topic(Name=name)
    try:
        assert a["TopicArn"] == b["TopicArn"]
    finally:
        sns.delete_topic(TopicArn=a["TopicArn"])


def test_create_topic_invalid_name(sns):
    with pytest.raises(botocore.exceptions.ClientError) as exc:
        sns.create_topic(Name="has space")
    assert exc.value.response["Error"]["Code"] == "InvalidParameter"


def test_create_topic_fifo_rejected(sns):
    """FIFO topics deferred to a later patch — `.fifo` suffix → InvalidParameter."""
    with pytest.raises(botocore.exceptions.ClientError) as exc:
        sns.create_topic(Name=f"{_name()}.fifo")
    assert exc.value.response["Error"]["Code"] == "InvalidParameter"


def test_list_topics_includes_created(sns):
    name = _name()
    arn = sns.create_topic(Name=name)["TopicArn"]
    try:
        out = sns.list_topics()
        arns = [t["TopicArn"] for t in out["Topics"]]
        assert arn in arns
    finally:
        sns.delete_topic(TopicArn=arn)


def test_get_topic_attributes_includes_owner_arn(sns):
    name = _name()
    arn = sns.create_topic(Name=name)["TopicArn"]
    try:
        out = sns.get_topic_attributes(TopicArn=arn)
        attrs = out["Attributes"]
        assert attrs["TopicArn"] == arn
        assert attrs["Owner"] == "000000000000"
        assert "SubscriptionsConfirmed" in attrs
    finally:
        sns.delete_topic(TopicArn=arn)


def test_set_topic_attributes_display_name_round_trip(sns):
    name = _name()
    arn = sns.create_topic(Name=name)["TopicArn"]
    try:
        sns.set_topic_attributes(TopicArn=arn, AttributeName="DisplayName", AttributeValue="My Topic")
        attrs = sns.get_topic_attributes(TopicArn=arn)["Attributes"]
        assert attrs.get("DisplayName") == "My Topic"
    finally:
        sns.delete_topic(TopicArn=arn)


def test_delete_topic_is_idempotent(sns):
    name = _name()
    arn = sns.create_topic(Name=name)["TopicArn"]
    sns.delete_topic(TopicArn=arn)
    # Second delete also succeeds (matches AWS).
    sns.delete_topic(TopicArn=arn)


def test_topics_survive_restart():
    bin_path = os.environ.get("NANOSTACK_BIN")
    if not bin_path:
        pytest.skip("NANOSTACK_BIN not set")

    data_dir = tempfile.mkdtemp(prefix="ns-sns-")
    port = _pick_port()
    ep = f"http://127.0.0.1:{port}"

    def spawn():
        return subprocess.Popen(
            [bin_path, "--port", str(port), "--data-dir", data_dir, "--services", "sns"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    proc = spawn()
    try:
        _wait_ready(port)
        sns_a = _make_sns(ep)
        name = _name()
        arn = sns_a.create_topic(Name=name)["TopicArn"]
        sns_a.set_topic_attributes(TopicArn=arn, AttributeName="DisplayName", AttributeValue="Persist")
    finally:
        proc.terminate()
        proc.wait(timeout=5)

    proc = spawn()
    try:
        _wait_ready(port)
        sns_b = _make_sns(ep)
        out = sns_b.list_topics()
        arns = [t["TopicArn"] for t in out["Topics"]]
        assert arn in arns
        attrs = sns_b.get_topic_attributes(TopicArn=arn)["Attributes"]
        assert attrs.get("DisplayName") == "Persist"
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
