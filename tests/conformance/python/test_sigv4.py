"""SigV4 conformance: header auth + presigned URLs.

The "custom-header presigned URL — request sent WITHOUT the header" test is
the regression for the LocalStack bug we exist to fix (#5269, #4133, #10844).
"""

import os
import socket
import subprocess
import time

import pytest
import requests
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

from conftest import (
    SHA256_EMPTY,
    aws_test_credentials,
    best_effort_delete_bucket,
    endpoint,
    endpoint_host,
    flip_last_hex,
    presign_with_header,
    sign_and_send,
)


def test_anonymous_request_is_denied():
    resp = requests.get(endpoint() + "/", timeout=5)
    assert resp.status_code == 403
    assert "<Code>AccessDenied</Code>" in resp.text


def test_bad_signature_is_rejected():
    # Sign a GET on the root with SigV4, tamper the signature, replay.
    req = AWSRequest(method="GET", url=endpoint() + "/", data=b"",
                     headers={"host": endpoint_host(), "x-amz-content-sha256": SHA256_EMPTY})
    SigV4Auth(aws_test_credentials(), "s3", "us-east-1").add_auth(req)
    auth = req.headers["Authorization"]
    assert "Signature=" in auth
    idx = auth.index("Signature=")
    sig = auth[idx + len("Signature="):]
    tampered = auth[: idx + len("Signature=")] + flip_last_hex(sig)
    headers = dict(req.headers.items())
    headers["Authorization"] = tampered

    resp = requests.get(endpoint() + "/", headers=headers, timeout=5)
    assert resp.status_code == 403
    assert "<Code>SignatureDoesNotMatch</Code>" in resp.text


def test_presigned_happy_path():
    """Presigned HEAD against a missing bucket → 404 (auth passed)."""
    url = presign_with_header("HEAD", "/no-such-bucket-presign/k", "host", endpoint_host())
    resp = requests.head(url, timeout=5)
    assert resp.status_code == 404


def test_presigned_expired():
    """Presigned URL with X-Amz-Expires=1 signed 5s ago → 403."""
    # Use Date 5s in past with 1s expiry → expired.
    import datetime

    creds = aws_test_credentials()
    past = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=5)
    url = endpoint() + "/test-bucket/test-key"
    req = AWSRequest(method="HEAD", url=url, data=b"", headers={"host": endpoint_host()})
    req.context["payload_signing_enabled"] = False
    req.context["timestamp"] = past.strftime("%Y%m%dT%H%M%SZ")
    from botocore.auth import S3SigV4QueryAuth
    auth = S3SigV4QueryAuth(creds, "s3", "us-east-1", expires=1)
    # Set the timestamp on the signer; botocore reads it from req.context.
    auth.add_auth(req)
    # The signer doesn't honour an arbitrary timestamp directly — patch the
    # X-Amz-Date query param manually so the server sees the expired stamp.
    from urllib.parse import urlparse, parse_qsl, urlencode
    pr = urlparse(req.url)
    qs = dict(parse_qsl(pr.query, keep_blank_values=True))
    qs["X-Amz-Date"] = past.strftime("%Y%m%dT%H%M%SZ")
    presigned = pr._replace(query=urlencode(qs)).geturl()
    resp = requests.head(presigned, timeout=5)
    assert resp.status_code == 403


def test_presigned_custom_header_happy(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        url = presign_with_header("HEAD", f"/{bucket_name}", "x-nano-custom", "value-1")
        resp = requests.head(url, headers={"x-nano-custom": "value-1"}, timeout=5)
        assert resp.status_code == 200, resp.text
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_presigned_custom_header_missing(s3, bucket_name):
    """LocalStack regression: same presigned URL, header omitted → clean 403."""
    s3.create_bucket(Bucket=bucket_name)
    try:
        url = presign_with_header("GET", f"/{bucket_name}", "x-nano-custom", "value-1")
        resp = requests.get(url, timeout=5)
        assert resp.status_code == 403
        assert "<Code>SignatureDoesNotMatch</Code>" in resp.text
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_no_auth_flag_accepts_anonymous():
    bin_path = os.environ.get("NANOSTACK_BIN")
    if not bin_path:
        pytest.skip("NANOSTACK_BIN not set; skipping --no-auth subprocess test")

    # Pick a free port (mostly defensive — 14999 is normally idle).
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]

    import tempfile, shutil
    data_dir = tempfile.mkdtemp(prefix="ns-noauth-")
    proc = subprocess.Popen(
        [bin_path, "--port", str(port), "--data-dir", data_dir, "--no-auth"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    try:
        url = f"http://127.0.0.1:{port}/"
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                resp = requests.get(url, timeout=1)
                if resp.status_code == 200:
                    return
            except requests.RequestException:
                pass
            time.sleep(0.1)
        raise AssertionError("nanostack --no-auth did not accept anonymous GET / within 5s")
    finally:
        proc.kill()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        shutil.rmtree(data_dir, ignore_errors=True)
