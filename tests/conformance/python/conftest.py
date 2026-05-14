"""Shared pytest fixtures + helpers for the nanostack conformance suite.

Drives the official AWS Python SDK (boto3) against a running nanostack at
the `NANOSTACK_ENDPOINT` env var (defaults to http://127.0.0.1:4577).
"""

from __future__ import annotations

import os
import re
import secrets
import time
from typing import Iterator

import boto3
import botocore.exceptions
import pytest
from botocore.config import Config


# ---------------------------------------------------------------------------
# Constants

# Every non-final part of a multipart upload must be ≥ 5 MiB per AWS S3.
MIN_PART_SIZE = 5 * 1024 * 1024


# ---------------------------------------------------------------------------
# Client + endpoint helpers

def endpoint() -> str:
    return os.environ.get("NANOSTACK_ENDPOINT", "http://127.0.0.1:4577")


def make_client() -> "boto3.client":
    """Build a boto3 S3 client configured for the local nanostack endpoint.

    Static `test`/`test` credentials match the nanostack defaults; path
    style addressing is required because there's no DNS for virtual hosts
    in local dev; SigV4 is enforced.
    """
    return boto3.client(
        "s3",
        endpoint_url=endpoint(),
        region_name="us-east-1",
        aws_access_key_id="test",
        aws_secret_access_key="test",
        config=Config(
            signature_version="s3v4",
            s3={"addressing_style": "path"},
            retries={"max_attempts": 1, "mode": "standard"},
            connect_timeout=5,
            read_timeout=10,
        ),
    )


@pytest.fixture
def s3():
    """One boto3 client per test."""
    return make_client()


# ---------------------------------------------------------------------------
# Unique bucket name

_INVALID_CHARS = re.compile(r"[^a-z0-9-]")


def _sanitize(name: str) -> str:
    name = name.lower()
    name = _INVALID_CHARS.sub("-", name)
    # Slice first, then strip: AWS forbids leading/trailing hyphens, and
    # the slice may land on one.
    return name.strip("-")[:30].strip("-")


def unique_bucket(prefix: str, *, suffix: str | None = None) -> str:
    """Bucket name guaranteed unique across concurrent runs + AWS-name-valid.

    AWS rules: 3–63 chars, lowercase + digits + `-`/`.`, no underscores,
    no uppercase. Suffix uses the request_node name (or a random hex
    when called outside a test). We compose `{prefix}-{suffix}-{ts}-{rand}`
    where suffix is capped at 30 chars (so the timestamp + random hex
    survive the AWS 63-char limit) and `{ts}{rand}` guarantees uniqueness
    even when xdist workers hit the same microsecond.
    """
    tail = suffix if suffix is not None else secrets.token_hex(4)
    tail_sanitised = _sanitize(tail)  # ≤ 30 chars, AWS-name-valid
    ts = int(time.time() * 1e6) % 10_000_000_000
    rand = secrets.token_hex(3)  # 6 hex chars
    composed = f"{prefix}-{tail_sanitised}-{ts}-{rand}"
    # composed length ≤ 2 + 30 + 1 + 10 + 1 + 6 = 50 chars — well under AWS's 63.
    return composed.strip("-")


@pytest.fixture
def bucket_name(request) -> str:
    """A unique bucket name derived from the current test name."""
    return unique_bucket(prefix="t", suffix=_sanitize(request.node.name))


# ---------------------------------------------------------------------------
# Cleanup

def best_effort_delete_bucket(s3, bucket: str) -> None:
    """Delete a bucket if it exists, ignoring all errors. Use as cleanup."""
    try:
        s3.delete_bucket(Bucket=bucket)
    except botocore.exceptions.ClientError:
        pass


def drain_versions(s3, bucket: str) -> None:
    """Permanently delete every object version + delete marker in a bucket.

    Required before deleting a versioned bucket. Honours bypass-governance
    so locked objects can also be drained from test buckets.
    """
    try:
        resp = s3.list_object_versions(Bucket=bucket)
    except botocore.exceptions.ClientError:
        return
    for v in resp.get("Versions", []) or []:
        try:
            s3.delete_object(
                Bucket=bucket,
                Key=v["Key"],
                VersionId=v["VersionId"],
                BypassGovernanceRetention=True,
            )
        except botocore.exceptions.ClientError:
            pass
    for m in resp.get("DeleteMarkers", []) or []:
        try:
            s3.delete_object(Bucket=bucket, Key=m["Key"], VersionId=m["VersionId"])
        except botocore.exceptions.ClientError:
            pass


def empty_bucket(s3, bucket: str) -> None:
    """Best-effort: empty every object + version + multipart from a bucket."""
    # Abort in-flight multipart uploads.
    try:
        mpus = s3.list_multipart_uploads(Bucket=bucket).get("Uploads", []) or []
        for u in mpus:
            try:
                s3.abort_multipart_upload(Bucket=bucket, Key=u["Key"], UploadId=u["UploadId"])
            except botocore.exceptions.ClientError:
                pass
    except botocore.exceptions.ClientError:
        pass
    # Versioned: drain all versions.
    drain_versions(s3, bucket)
    # Flat: delete all objects.
    try:
        objs = s3.list_objects_v2(Bucket=bucket).get("Contents", []) or []
        for o in objs:
            try:
                s3.delete_object(Bucket=bucket, Key=o["Key"])
            except botocore.exceptions.ClientError:
                pass
    except botocore.exceptions.ClientError:
        pass


# ---------------------------------------------------------------------------
# Seed helpers

def seed_object(s3, bucket: str, key: str, body: bytes | str = b"hello") -> None:
    """Create the bucket (if needed) and put a small object."""
    if isinstance(body, str):
        body = body.encode("utf-8")
    try:
        s3.create_bucket(Bucket=bucket)
    except botocore.exceptions.ClientError as e:
        if e.response.get("Error", {}).get("Code") not in {"BucketAlreadyOwnedByYou", "BucketAlreadyExists"}:
            raise
    s3.put_object(Bucket=bucket, Key=key, Body=body)


def make_payload(size: int, byte: bytes = b"A") -> bytes:
    """A `size`-byte buffer filled with the same byte. Used for multipart parts."""
    if len(byte) != 1:
        raise ValueError("byte must be a single-byte bytes object")
    return byte * size


# ---------------------------------------------------------------------------
# Error-inspection helpers

def aws_error_code(exc: botocore.exceptions.ClientError) -> str:
    """Pull the `<Code>` from a boto3 ClientError."""
    return exc.response.get("Error", {}).get("Code", "")


def aws_http_status(exc: botocore.exceptions.ClientError) -> int:
    """Pull the HTTP status code from a boto3 ClientError."""
    return exc.response.get("ResponseMetadata", {}).get("HTTPStatusCode", 0)


# ---------------------------------------------------------------------------
# Autouse fixture: ensure no stray state from prior tests
#
# Each test that creates a bucket should use the `bucket_name` fixture +
# clean up itself. We don't autouse cleanup here because individual tests
# may keep buckets alive for assertions on Get/Head behaviour.


# ---------------------------------------------------------------------------
# Hand-signed HTTP (for raw range checks, SigV4 regression tests, and ops
# the SDK doesn't expose cleanly — UpdateObjectEncryption etc.)

import hashlib
from urllib.parse import urlparse

import requests
from botocore.auth import SigV4Auth, S3SigV4QueryAuth
from botocore.awsrequest import AWSRequest
from botocore.credentials import Credentials


SHA256_EMPTY = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"


def aws_test_credentials() -> Credentials:
    """Static creds matching nanostack defaults (`test`/`test`)."""
    return Credentials("test", "test")


def endpoint_host() -> str:
    """Host:port the SDK should sign with — derived from NANOSTACK_ENDPOINT."""
    return urlparse(endpoint()).netloc or "127.0.0.1:4577"


def sign_and_send(method: str, path: str, *, body: bytes = b"",
                  headers: dict | None = None, payload_hash: str | None = None) -> requests.Response:
    """Sign a SigV4 request and send it via the `requests` library.

    `path` is a path+query, starts with `/`. Caller can pass `payload_hash`
    for non-empty bodies (defaults to the SHA256 of the body bytes).
    """
    if payload_hash is None:
        payload_hash = hashlib.sha256(body).hexdigest() if body else SHA256_EMPTY

    url = endpoint() + path
    hdrs = dict(headers or {})
    hdrs["host"] = endpoint_host()
    hdrs["x-amz-content-sha256"] = payload_hash

    req = AWSRequest(method=method, url=url, data=body, headers=hdrs)
    SigV4Auth(aws_test_credentials(), "s3", "us-east-1").add_auth(req)
    return requests.request(
        method=req.method,
        url=req.url,
        data=req.body,
        headers=dict(req.headers.items()),
        timeout=10,
    )


def presign_with_header(method: str, path: str, header_name: str, header_value: str,
                        *, expires: int = 3600) -> str:
    """Presign a URL with `header_name` listed in X-Amz-SignedHeaders.

    The Go SDK's presigner doesn't natively expose this; same for boto3's
    `generate_presigned_url`. We drop to `S3SigV4QueryAuth` directly.
    """
    url = endpoint() + path
    headers = {
        "host": endpoint_host(),
        header_name.lower(): header_value,
    }
    req = AWSRequest(method=method, url=url, data=b"", headers=headers)
    req.context["payload_signing_enabled"] = False  # UNSIGNED-PAYLOAD
    S3SigV4QueryAuth(aws_test_credentials(), "s3", "us-east-1", expires=expires).add_auth(req)
    return req.url


def flip_last_hex(s: str) -> str:
    if not s:
        return s
    last = s[-1]
    alt = "1" if last == "0" else ("e" if last == "f" else "0")
    return s[:-1] + alt
