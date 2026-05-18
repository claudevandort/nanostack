"""Topic Policy enforcement conformance — v0.4.2.

Verifies the SNS authz hook actually evaluates the persisted Policy
attribute, rather than accepting AddPermission / SetTopicAttributes
calls + ignoring them. Mirrors `sqs/test_queue_policy_enforcement.py`.

SNS wire protocol divergence vs SQS: form-encoded body, XML response,
`<Code>AuthorizationError</Code>` instead of JSON `__type`.
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
import pytest
import requests
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


def _make_sqs(ep: str | None = None):
    return boto3.client(
        "sqs",
        endpoint_url=ep or endpoint(),
        region_name="us-east-1",
        aws_access_key_id="test",
        aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 1}),
    )


@pytest.fixture
def sns():
    return _make_sns()


# ---------------------------------------------------------------------------
# Helpers


def anon_sns_call(action: str, params: dict, ep: str | None = None) -> requests.Response:
    """Unsigned form-encoded POST — exercises the anonymous-principal path."""
    body = {"Action": action, "Version": "2010-03-31", **params}
    return requests.post(
        ep or endpoint(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        data=body,
        timeout=5,
    )


def _xml_code(text: str) -> str:
    """Pull `<Code>X</Code>` out of an SNS XML error envelope."""
    start = text.find("<Code>")
    end = text.find("</Code>")
    if start == -1 or end == -1:
        return ""
    return text[start + len("<Code>") : end]


def _public_publish_policy(account_id: str, topic_name: str) -> str:
    return json.dumps({
        "Version": "2012-10-17",
        "Statement": [{
            "Sid": "PublicPublish",
            "Effect": "Allow",
            "Principal": "*",
            "Action": "sns:Publish",
            "Resource": f"arn:aws:sns:us-east-1:{account_id}:{topic_name}",
        }],
    })


def _public_all_with_deny_policy(account_id: str, topic_name: str) -> str:
    return json.dumps({
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "PublicAll",
                "Effect": "Allow",
                "Principal": "*",
                "Action": "*",
                "Resource": f"arn:aws:sns:us-east-1:{account_id}:{topic_name}",
            },
            {
                "Sid": "NoSubscribe",
                "Effect": "Deny",
                "Principal": "*",
                "Action": "sns:Subscribe",
                "Resource": f"arn:aws:sns:us-east-1:{account_id}:{topic_name}",
            },
        ],
    })


def _owner_deny_policy(account_id: str, topic_name: str) -> str:
    return json.dumps({
        "Version": "2012-10-17",
        "Statement": [{
            "Sid": "DenyAll",
            "Effect": "Deny",
            "Principal": "*",
            "Action": "*",
            "Resource": f"arn:aws:sns:us-east-1:{account_id}:{topic_name}",
        }],
    })


def _public_get_sub_attrs_policy(account_id: str, topic_name: str) -> str:
    return json.dumps({
        "Version": "2012-10-17",
        "Statement": [{
            "Sid": "PublicGetSubAttrs",
            "Effect": "Allow",
            "Principal": "*",
            "Action": "sns:GetSubscriptionAttributes",
            "Resource": f"arn:aws:sns:us-east-1:{account_id}:{topic_name}",
        }],
    })


# ---------------------------------------------------------------------------
# Owner path + anonymous-default-deny


def test_owner_no_policy_can_publish(sns):
    name = f"t_{secrets.token_hex(4)}"
    arn = sns.create_topic(Name=name)["TopicArn"]
    try:
        out = sns.publish(TopicArn=arn, Message="owner-msg")
        assert "MessageId" in out
    finally:
        sns.delete_topic(TopicArn=arn)


def test_anonymous_no_policy_denied(sns):
    name = f"t_{secrets.token_hex(4)}"
    arn = sns.create_topic(Name=name)["TopicArn"]
    try:
        resp = anon_sns_call("Publish", {"TopicArn": arn, "Message": "anon"})
        assert resp.status_code == 403, resp.text
        assert _xml_code(resp.text) == "AuthorizationError"
    finally:
        sns.delete_topic(TopicArn=arn)


def test_anonymous_with_public_publish_policy_allowed(sns):
    name = f"t_{secrets.token_hex(4)}"
    arn = sns.create_topic(Name=name)["TopicArn"]
    try:
        sns.set_topic_attributes(
            TopicArn=arn,
            AttributeName="Policy",
            AttributeValue=_public_publish_policy("000000000000", name),
        )
        resp = anon_sns_call("Publish", {"TopicArn": arn, "Message": "anon"})
        assert resp.status_code == 200, resp.text
        assert "<MessageId>" in resp.text
    finally:
        sns.delete_topic(TopicArn=arn)


def test_anonymous_action_mismatch_denied(sns):
    """Policy grants Publish only — anonymous Subscribe still 403."""
    name = f"t_{secrets.token_hex(4)}"
    arn = sns.create_topic(Name=name)["TopicArn"]
    try:
        sns.set_topic_attributes(
            TopicArn=arn,
            AttributeName="Policy",
            AttributeValue=_public_publish_policy("000000000000", name),
        )
        resp = anon_sns_call(
            "Subscribe",
            {"TopicArn": arn, "Protocol": "sqs",
             "Endpoint": "arn:aws:sqs:us-east-1:000000000000:nowhere"},
        )
        assert resp.status_code == 403
    finally:
        sns.delete_topic(TopicArn=arn)


# ---------------------------------------------------------------------------
# Allow + Deny interaction


def test_explicit_deny_overrides_allow(sns):
    """Allow * + Deny sns:Subscribe — anon Publish ok, Subscribe denied."""
    name = f"t_{secrets.token_hex(4)}"
    arn = sns.create_topic(Name=name)["TopicArn"]
    try:
        sns.set_topic_attributes(
            TopicArn=arn,
            AttributeName="Policy",
            AttributeValue=_public_all_with_deny_policy("000000000000", name),
        )
        r1 = anon_sns_call("Publish", {"TopicArn": arn, "Message": "hi"})
        assert r1.status_code == 200, r1.text
        r2 = anon_sns_call(
            "Subscribe",
            {"TopicArn": arn, "Protocol": "sqs",
             "Endpoint": "arn:aws:sqs:us-east-1:000000000000:nowhere"},
        )
        assert r2.status_code == 403
    finally:
        sns.delete_topic(TopicArn=arn)


# ---------------------------------------------------------------------------
# Owner bypass + --no-auth bypass


def test_owner_bypasses_deny_policy(sns):
    """Deny * doesn't lock out the topic owner."""
    name = f"t_{secrets.token_hex(4)}"
    arn = sns.create_topic(Name=name)["TopicArn"]
    try:
        sns.set_topic_attributes(
            TopicArn=arn,
            AttributeName="Policy",
            AttributeValue=_owner_deny_policy("000000000000", name),
        )
        out = sns.publish(TopicArn=arn, Message="owner")
        assert "MessageId" in out
    finally:
        sns.delete_topic(TopicArn=arn)


def test_no_auth_bypasses_policy():
    bin_path = os.environ.get("NANOSTACK_BIN")
    if not bin_path:
        pytest.skip("NANOSTACK_BIN not set")
    data_dir = tempfile.mkdtemp(prefix="ns-sns-policy-")
    port = _pick_port()
    ep = f"http://127.0.0.1:{port}"
    proc = subprocess.Popen(
        [bin_path, "--port", str(port), "--data-dir", data_dir,
         "--services", "sns", "--no-auth"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        _wait_ready(port)
        s = _make_sns(ep)
        name = f"t_{secrets.token_hex(4)}"
        arn = s.create_topic(Name=name)["TopicArn"]
        s.set_topic_attributes(
            TopicArn=arn,
            AttributeName="Policy",
            AttributeValue=_owner_deny_policy("000000000000", name),
        )
        resp = anon_sns_call("Publish", {"TopicArn": arn, "Message": "x"}, ep)
        assert resp.status_code == 200, resp.text
    finally:
        proc.terminate()
        proc.wait(timeout=5)


# ---------------------------------------------------------------------------
# Account-scoped


def test_anonymous_create_topic_denied():
    resp = anon_sns_call("CreateTopic", {"Name": f"anon_t_{secrets.token_hex(4)}"})
    assert resp.status_code == 403


def test_owner_create_topic_allowed(sns):
    name = f"t_{secrets.token_hex(4)}"
    arn = sns.create_topic(Name=name)["TopicArn"]
    try:
        assert arn
    finally:
        sns.delete_topic(TopicArn=arn)


# ---------------------------------------------------------------------------
# Subscription-arn op: policy evaluated against parent topic


def test_sub_arn_op_evaluated_against_parent_topic(sns):
    """GetSubscriptionAttributes uses SubscriptionArn but is gated by the
    parent topic's Policy. Owner can always read; anon needs an explicit
    Allow on `sns:GetSubscriptionAttributes`."""
    sqs = _make_sqs()
    qname = f"sqs_{secrets.token_hex(4)}"
    tname = f"t_{secrets.token_hex(4)}"
    qurl = sqs.create_queue(QueueName=qname)["QueueUrl"]
    arn = sns.create_topic(Name=tname)["TopicArn"]
    try:
        sub_arn = sns.subscribe(
            TopicArn=arn,
            Protocol="sqs",
            Endpoint=f"arn:aws:sqs:us-east-1:000000000000:{qname}",
        )["SubscriptionArn"]
        # Anonymous without policy → 403.
        r0 = anon_sns_call("GetSubscriptionAttributes", {"SubscriptionArn": sub_arn})
        assert r0.status_code == 403
        # Grant anon GetSubscriptionAttributes on the topic.
        sns.set_topic_attributes(
            TopicArn=arn,
            AttributeName="Policy",
            AttributeValue=_public_get_sub_attrs_policy("000000000000", tname),
        )
        r1 = anon_sns_call("GetSubscriptionAttributes", {"SubscriptionArn": sub_arn})
        assert r1.status_code == 200, r1.text
        assert "<key>TopicArn</key>" in r1.text
    finally:
        sns.delete_topic(TopicArn=arn)
        sqs.delete_queue(QueueUrl=qurl)


# ---------------------------------------------------------------------------
# Helpers


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
