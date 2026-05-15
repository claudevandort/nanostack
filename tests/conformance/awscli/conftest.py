"""Shared pytest fixtures + helpers for the AWS CLI conformance suite.

Drives `aws s3` v2 against a running nanostack at the `NANOSTACK_ENDPOINT`
env var (defaults to http://127.0.0.1:4577). Each test invocation runs the
real `aws` binary via `subprocess.run` with the nanostack endpoint baked in
and isolated static credentials (`test`/`test`).
"""

from __future__ import annotations

import json
import os
import re
import secrets
import subprocess
import time
from dataclasses import dataclass
from typing import Any, Sequence

import pytest


# ---------------------------------------------------------------------------
# Endpoint + env

def endpoint() -> str:
    return os.environ.get("NANOSTACK_ENDPOINT", "http://127.0.0.1:4577")


def aws_env() -> dict[str, str]:
    """Process env with static credentials + region overridden.

    Returns a fresh dict each call so tests can mutate locally without
    leaking into siblings.
    """
    env = dict(os.environ)
    env.update({
        "AWS_ACCESS_KEY_ID": "test",
        "AWS_SECRET_ACCESS_KEY": "test",
        "AWS_DEFAULT_REGION": "us-east-1",
        # Defensive: silence any pager that might wrap stdout.
        "AWS_PAGER": "",
    })
    return env


# ---------------------------------------------------------------------------
# CLI runner

@dataclass
class AwsResult:
    args: list[str]
    returncode: int
    stdout: str
    stderr: str

    def ok(self) -> bool:
        return self.returncode == 0

    def json(self) -> Any:
        return json.loads(self.stdout)

    def __repr__(self) -> str:
        return f"AwsResult(args={self.args!r}, rc={self.returncode}, stdout={self.stdout!r}, stderr={self.stderr!r})"


def run_aws(*args: str, check: bool = True, json_output: bool = False,
            timeout: float = 30.0) -> AwsResult:
    """Run `aws <args> --endpoint-url $NANOSTACK_ENDPOINT` via subprocess.

    If `json_output` is True, appends `--output json` so `result.json()` works.
    `check=True` raises on non-zero exit (with the AwsResult in the exception
    chain for visibility).
    """
    cli_args: list[str] = list(args) + ["--endpoint-url", endpoint()]
    if json_output:
        cli_args.extend(["--output", "json"])

    proc = subprocess.run(
        ["aws", *cli_args],
        env=aws_env(),
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    result = AwsResult(
        args=cli_args,
        returncode=proc.returncode,
        stdout=proc.stdout,
        stderr=proc.stderr,
    )
    if check and not result.ok():
        raise AssertionError(f"aws CLI failed: {result!r}")
    return result


# ---------------------------------------------------------------------------
# Bucket naming

_INVALID_CHARS = re.compile(r"[^a-z0-9-]")


def _sanitize(name: str) -> str:
    name = name.lower()
    name = _INVALID_CHARS.sub("-", name)
    return name.strip("-")[:30].strip("-")


def unique_bucket(prefix: str = "t", *, suffix: str | None = None) -> str:
    """AWS-name-valid unique bucket name: `{prefix}-{suffix}-{ts}-{rand}`.

    Caps at well under AWS's 63-char limit. Concurrent runs hash into
    distinct names via the timestamp + random tail.
    """
    tail = suffix if suffix is not None else secrets.token_hex(4)
    tail_sanitised = _sanitize(tail)
    ts = int(time.time() * 1e6) % 10_000_000_000
    rand = secrets.token_hex(3)
    composed = f"{prefix}-{tail_sanitised}-{ts}-{rand}"
    return composed.strip("-")


@pytest.fixture
def bucket_name(request) -> str:
    """A unique bucket name derived from the current test name."""
    return unique_bucket(prefix="t", suffix=_sanitize(request.node.name))


# ---------------------------------------------------------------------------
# Lifecycle helpers

def make_bucket(name: str) -> None:
    """Best-effort `aws s3 mb s3://<name>`. Raises on failure."""
    run_aws("s3", "mb", f"s3://{name}")


def delete_bucket_force(name: str) -> None:
    """Best-effort cleanup: `aws s3 rb s3://<name> --force`. Swallows errors."""
    run_aws("s3", "rb", f"s3://{name}", "--force", check=False)


@pytest.fixture
def bucket(bucket_name: str):
    """Create the bucket, yield its name, force-delete on teardown."""
    make_bucket(bucket_name)
    try:
        yield bucket_name
    finally:
        delete_bucket_force(bucket_name)
