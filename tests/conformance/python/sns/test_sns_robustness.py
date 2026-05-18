"""SNS robustness conformance — v0.4.1.

Phase A: tags persistence across restart.
Phase B: AddPermission / RemovePermission.
Phase C: PublishBatch MessageAttributes.
Phase D: FilterPolicy evaluation.
"""

from __future__ import annotations

import json
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
        "sns", endpoint_url=ep or endpoint(), region_name="us-east-1",
        aws_access_key_id="test", aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 1}),
    )


def _make_sqs(ep: str | None = None):
    return boto3.client(
        "sqs", endpoint_url=ep or endpoint(), region_name="us-east-1",
        aws_access_key_id="test", aws_secret_access_key="test",
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
    bin_path = os.environ.get("NANOSTACK_BIN")
    if not bin_path:
        pytest.skip("NANOSTACK_BIN not set")
    data_dir = tempfile.mkdtemp(prefix="ns-sns-robust-")
    port = _pick_port()
    ep = f"http://127.0.0.1:{port}"

    procs: list[subprocess.Popen] = []

    def spawn():
        p = subprocess.Popen(
            [bin_path, "--port", str(port), "--data-dir", data_dir, "--services", "sns,sqs"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        procs.append(p)
        _wait_ready(port)
        return p

    yield spawn, ep
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()


@pytest.fixture
def sns():
    return _make_sns()


@pytest.fixture
def sqs():
    return _make_sqs()


# ---------- Phase A — Tags persistence ----------


def test_tags_survive_restart(restartable):
    spawn, ep = restartable
    proc = spawn()
    name = f"t_{secrets.token_hex(4)}"
    sns_a = _make_sns(ep)
    arn = sns_a.create_topic(Name=name)["TopicArn"]
    sns_a.tag_resource(ResourceArn=arn, Tags=[
        {"Key": "env", "Value": "dev"},
        {"Key": "team", "Value": "infra"},
    ])
    proc.terminate()
    proc.wait(timeout=5)

    spawn()
    sns_b = _make_sns(ep)
    out = sns_b.list_tags_for_resource(ResourceArn=arn)
    tags = {t["Key"]: t["Value"] for t in out["Tags"]}
    assert tags == {"env": "dev", "team": "infra"}


def test_untag_persists_across_restart(restartable):
    spawn, ep = restartable
    proc = spawn()
    name = f"t_{secrets.token_hex(4)}"
    sns_a = _make_sns(ep)
    arn = sns_a.create_topic(Name=name)["TopicArn"]
    sns_a.tag_resource(ResourceArn=arn, Tags=[
        {"Key": "a", "Value": "1"}, {"Key": "b", "Value": "2"},
    ])
    sns_a.untag_resource(ResourceArn=arn, TagKeys=["a"])
    proc.terminate()
    proc.wait(timeout=5)

    spawn()
    sns_b = _make_sns(ep)
    out = sns_b.list_tags_for_resource(ResourceArn=arn)
    tags = {t["Key"]: t["Value"] for t in out["Tags"]}
    assert tags == {"b": "2"}


def test_retag_after_restart_works(restartable):
    spawn, ep = restartable
    proc = spawn()
    name = f"t_{secrets.token_hex(4)}"
    sns_a = _make_sns(ep)
    arn = sns_a.create_topic(Name=name)["TopicArn"]
    sns_a.tag_resource(ResourceArn=arn, Tags=[{"Key": "env", "Value": "dev"}])
    proc.terminate()
    proc.wait(timeout=5)

    spawn()
    sns_b = _make_sns(ep)
    sns_b.tag_resource(ResourceArn=arn, Tags=[{"Key": "env", "Value": "prod"}])
    out = sns_b.list_tags_for_resource(ResourceArn=arn)
    tags = {t["Key"]: t["Value"] for t in out["Tags"]}
    assert tags == {"env": "prod"}


# ---------- Phase B — AddPermission / RemovePermission ----------


def test_add_permission_creates_policy(sns):
    arn = sns.create_topic(Name=f"t_{secrets.token_hex(4)}")["TopicArn"]
    try:
        sns.add_permission(
            TopicArn=arn, Label="grant1",
            AWSAccountId=["111122223333"], ActionName=["Publish"],
        )
        attrs = sns.get_topic_attributes(TopicArn=arn)["Attributes"]
        policy = attrs.get("Policy")
        assert policy is not None
        assert "grant1" in policy
        assert "111122223333" in policy
        assert "sns:Publish" in policy
    finally:
        sns.delete_topic(TopicArn=arn)


def test_add_permission_appends_to_existing(sns):
    arn = sns.create_topic(Name=f"t_{secrets.token_hex(4)}")["TopicArn"]
    try:
        sns.add_permission(
            TopicArn=arn, Label="grant1",
            AWSAccountId=["111122223333"], ActionName=["Publish"],
        )
        sns.add_permission(
            TopicArn=arn, Label="grant2",
            AWSAccountId=["444455556666"], ActionName=["Subscribe"],
        )
        policy = sns.get_topic_attributes(TopicArn=arn)["Attributes"]["Policy"]
        assert "grant1" in policy
        assert "grant2" in policy
        assert "sns:Publish" in policy
        assert "sns:Subscribe" in policy
    finally:
        sns.delete_topic(TopicArn=arn)


def test_add_permission_duplicate_label_rejected(sns):
    arn = sns.create_topic(Name=f"t_{secrets.token_hex(4)}")["TopicArn"]
    try:
        sns.add_permission(
            TopicArn=arn, Label="grant1",
            AWSAccountId=["111122223333"], ActionName=["Publish"],
        )
        with pytest.raises(botocore.exceptions.ClientError) as exc:
            sns.add_permission(
                TopicArn=arn, Label="grant1",
                AWSAccountId=["444455556666"], ActionName=["Subscribe"],
            )
        assert exc.value.response["Error"]["Code"] == "InvalidParameter"
    finally:
        sns.delete_topic(TopicArn=arn)


def test_remove_permission_drops_matching(sns):
    arn = sns.create_topic(Name=f"t_{secrets.token_hex(4)}")["TopicArn"]
    try:
        sns.add_permission(TopicArn=arn, Label="g1",
                           AWSAccountId=["111122223333"], ActionName=["Publish"])
        sns.add_permission(TopicArn=arn, Label="g2",
                           AWSAccountId=["444455556666"], ActionName=["Subscribe"])
        sns.remove_permission(TopicArn=arn, Label="g1")
        policy = sns.get_topic_attributes(TopicArn=arn)["Attributes"]["Policy"]
        assert "g1" not in policy
        assert "g2" in policy
    finally:
        sns.delete_topic(TopicArn=arn)


def test_remove_permission_clears_policy_when_empty(sns):
    arn = sns.create_topic(Name=f"t_{secrets.token_hex(4)}")["TopicArn"]
    try:
        sns.add_permission(TopicArn=arn, Label="g1",
                           AWSAccountId=["111122223333"], ActionName=["Publish"])
        sns.remove_permission(TopicArn=arn, Label="g1")
        attrs = sns.get_topic_attributes(TopicArn=arn)["Attributes"]
        # Policy attribute is gone after the last statement is removed.
        assert "Policy" not in attrs or not attrs["Policy"]
    finally:
        sns.delete_topic(TopicArn=arn)
