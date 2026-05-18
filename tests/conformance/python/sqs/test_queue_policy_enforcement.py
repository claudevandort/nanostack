"""Queue Policy enforcement conformance — v0.3.3.

These tests verify that nanostack's SQS authz hook actually consults
the persisted Policy attribute, rather than accepting AddPermission
calls + ignoring them. Anonymous requests, public-send policies,
Deny-statement overrides, and owner-implicit-allow are all exercised.
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
import requests
from botocore.config import Config

from conftest import endpoint


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
def sqs():
    return _make_sqs()


# ---------------------------------------------------------------------------
# Helpers


def anon_sqs_call(target: str, payload: dict, ep: str | None = None) -> requests.Response:
    """Unsigned POST — exercises the anonymous-principal path."""
    return requests.post(
        ep or endpoint(),
        headers={
            "X-Amz-Target": f"AmazonSQS.{target}",
            "Content-Type": "application/x-amz-json-1.0",
        },
        data=json.dumps(payload),
        timeout=5,
    )


def _public_send_policy(account_id: str, queue_name: str) -> str:
    """Build a policy that allows `sqs:SendMessage` for `Principal: *`."""
    return json.dumps({
        "Version": "2012-10-17",
        "Statement": [{
            "Sid": "PublicSend",
            "Effect": "Allow",
            "Principal": "*",
            "Action": "sqs:SendMessage",
            "Resource": f"arn:aws:sqs:us-east-1:{account_id}:{queue_name}",
        }],
    })


def _public_all_with_deny_policy(account_id: str, queue_name: str) -> str:
    """Allow everything, but explicitly Deny DeleteMessage."""
    return json.dumps({
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "PublicAll",
                "Effect": "Allow",
                "Principal": "*",
                "Action": "*",
                "Resource": f"arn:aws:sqs:us-east-1:{account_id}:{queue_name}",
            },
            {
                "Sid": "NoDelete",
                "Effect": "Deny",
                "Principal": "*",
                "Action": "sqs:DeleteMessage",
                "Resource": f"arn:aws:sqs:us-east-1:{account_id}:{queue_name}",
            },
        ],
    })


def _owner_deny_policy(account_id: str, queue_name: str) -> str:
    """Deny everything from everyone — owner should still bypass via owner-implicit-allow."""
    return json.dumps({
        "Version": "2012-10-17",
        "Statement": [{
            "Sid": "DenyAll",
            "Effect": "Deny",
            "Principal": "*",
            "Action": "*",
            "Resource": f"arn:aws:sqs:us-east-1:{account_id}:{queue_name}",
        }],
    })


# ---------------------------------------------------------------------------
# Owner path + anonymous-default-deny


def test_owner_no_policy_can_send(sqs):
    """Sanity: signed-with-configured-key requests work without any policy
    (owner-implicit-allow)."""
    name = f"q_{secrets.token_hex(4)}"
    url = sqs.create_queue(QueueName=name)["QueueUrl"]
    try:
        out = sqs.send_message(QueueUrl=url, MessageBody="hi")
        assert "MessageId" in out
    finally:
        sqs.delete_queue(QueueUrl=url)


def test_anonymous_no_policy_denied(sqs):
    """Default state: queue has no policy → anonymous can't send."""
    name = f"q_{secrets.token_hex(4)}"
    url = sqs.create_queue(QueueName=name)["QueueUrl"]
    try:
        resp = anon_sqs_call("SendMessage", {"QueueUrl": url, "MessageBody": "anon"})
        assert resp.status_code == 403
        body = resp.json()
        assert "AccessDenied" in body.get("__type", "")
    finally:
        sqs.delete_queue(QueueUrl=url)


def test_anonymous_with_public_send_policy_allowed(sqs):
    """Policy allows `sqs:SendMessage` for `Principal: *` → anonymous send succeeds."""
    name = f"q_{secrets.token_hex(4)}"
    url = sqs.create_queue(QueueName=name)["QueueUrl"]
    try:
        sqs.set_queue_attributes(
            QueueUrl=url,
            Attributes={"Policy": _public_send_policy("000000000000", name)},
        )
        resp = anon_sqs_call("SendMessage", {"QueueUrl": url, "MessageBody": "anon"})
        assert resp.status_code == 200, resp.text
        # And the message actually landed.
        recv = sqs.receive_message(QueueUrl=url)
        assert recv["Messages"][0]["Body"] == "anon"
    finally:
        sqs.delete_queue(QueueUrl=url)


def test_anonymous_action_mismatch_denied(sqs):
    """Public-send policy doesn't grant ReceiveMessage → anonymous receive 403."""
    name = f"q_{secrets.token_hex(4)}"
    url = sqs.create_queue(QueueName=name)["QueueUrl"]
    try:
        sqs.set_queue_attributes(
            QueueUrl=url,
            Attributes={"Policy": _public_send_policy("000000000000", name)},
        )
        resp = anon_sqs_call("ReceiveMessage", {"QueueUrl": url})
        assert resp.status_code == 403
    finally:
        sqs.delete_queue(QueueUrl=url)


# ---------------------------------------------------------------------------
# Allow + Deny interaction


def test_explicit_deny_overrides_allow(sqs):
    """Statement with `Effect: Deny sqs:DeleteMessage` overrides the global allow.
    Anonymous can send + receive, but can't delete."""
    name = f"q_{secrets.token_hex(4)}"
    url = sqs.create_queue(QueueName=name)["QueueUrl"]
    try:
        sqs.set_queue_attributes(
            QueueUrl=url,
            Attributes={"Policy": _public_all_with_deny_policy("000000000000", name)},
        )
        # Send succeeds.
        r1 = anon_sqs_call("SendMessage", {"QueueUrl": url, "MessageBody": "hi"})
        assert r1.status_code == 200
        # Receive succeeds.
        r2 = anon_sqs_call("ReceiveMessage", {"QueueUrl": url})
        assert r2.status_code == 200
        rh = r2.json()["Messages"][0]["ReceiptHandle"]
        # Delete denied.
        r3 = anon_sqs_call(
            "DeleteMessage", {"QueueUrl": url, "ReceiptHandle": rh}
        )
        assert r3.status_code == 403
    finally:
        sqs.delete_queue(QueueUrl=url)


# ---------------------------------------------------------------------------
# Owner bypass + --no-auth bypass


def test_owner_bypasses_deny_policy(sqs):
    """A `Deny *` policy doesn't lock out the queue owner — owner-implicit-allow."""
    name = f"q_{secrets.token_hex(4)}"
    url = sqs.create_queue(QueueName=name)["QueueUrl"]
    try:
        sqs.set_queue_attributes(
            QueueUrl=url,
            Attributes={"Policy": _owner_deny_policy("000000000000", name)},
        )
        # Signed (owner) request still works.
        out = sqs.send_message(QueueUrl=url, MessageBody="owner")
        assert "MessageId" in out
    finally:
        # Drop the deny first so cleanup works (defensive — owner bypasses anyway).
        sqs.delete_queue(QueueUrl=url)


def test_no_auth_bypasses_policy():
    """`--no-auth` mode skips both SigV4 and the policy eval gate."""
    bin_path = os.environ.get("NANOSTACK_BIN")
    if not bin_path:
        pytest.skip("NANOSTACK_BIN not set")

    data_dir = tempfile.mkdtemp(prefix="ns-policy-")
    port = _pick_port()
    ep = f"http://127.0.0.1:{port}"
    proc = subprocess.Popen(
        [bin_path, "--port", str(port), "--data-dir", data_dir, "--services", "sqs", "--no-auth"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        _wait_ready(port)
        s = _make_sqs(ep)
        name = f"q_{secrets.token_hex(4)}"
        url = s.create_queue(QueueName=name)["QueueUrl"]
        s.set_queue_attributes(
            QueueUrl=url,
            Attributes={"Policy": _owner_deny_policy("000000000000", name)},
        )
        # Even with a deny-all policy + anonymous, --no-auth bypasses.
        resp = anon_sqs_call(
            "SendMessage", {"QueueUrl": url, "MessageBody": "x"}, ep
        )
        assert resp.status_code == 200, resp.text
    finally:
        proc.terminate()
        proc.wait(timeout=5)


# ---------------------------------------------------------------------------
# Account-scoped


def test_anonymous_create_queue_denied():
    """CreateQueue is account-scoped — anonymous denied."""
    resp = anon_sqs_call("CreateQueue", {"QueueName": f"anon_q_{secrets.token_hex(4)}"})
    assert resp.status_code == 403


def test_owner_create_queue_allowed(sqs):
    """Signed CreateQueue succeeds (sanity)."""
    name = f"q_{secrets.token_hex(4)}"
    url = sqs.create_queue(QueueName=name)["QueueUrl"]
    try:
        assert url
    finally:
        sqs.delete_queue(QueueUrl=url)


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
