"""S3 → SQS event-notification conformance via `aws s3` v2 CLI (v0.3.4)."""

from __future__ import annotations

import json
import os
import secrets
import tempfile
import time

import pytest

from conftest import run_aws


def _setup(bucket: str, events: list[str]):
    queue_name = f"cli_q_{secrets.token_hex(4)}"
    queue_url = run_aws(
        "sqs", "create-queue", "--queue-name", queue_name, json_output=True
    ).json()["QueueUrl"]
    run_aws("s3", "mb", f"s3://{bucket}")
    queue_arn = f"arn:aws:sqs:us-east-1:000000000000:{queue_name}"
    run_aws(
        "s3api", "put-bucket-notification-configuration",
        "--bucket", bucket,
        "--notification-configuration", json.dumps({
            "QueueConfigurations": [{
                "QueueArn": queue_arn,
                "Events": events,
            }],
        }),
    )
    return queue_url


def _temp_file_with(body: str) -> str:
    fd, path = tempfile.mkstemp(prefix="ns-ev-")
    with os.fdopen(fd, "w") as f:
        f.write(body)
    return path


def _drain(queue_url: str, max_wait_s: float = 5.0) -> list[dict]:
    deadline = time.time() + max_wait_s
    out: list[dict] = []
    while time.time() < deadline:
        r = run_aws(
            "sqs", "receive-message",
            "--queue-url", queue_url,
            "--max-number-of-messages", "10",
            "--wait-time-seconds", "1",
        )
        if not r.stdout.strip():
            if out:
                return out
            continue
        parsed = json.loads(r.stdout)
        msgs = parsed.get("Messages", [])
        if not msgs:
            if out:
                return out
            continue
        for m in msgs:
            body = json.loads(m["Body"])
            for rec in body.get("Records", []):
                out.append(rec)
            run_aws(
                "sqs", "delete-message",
                "--queue-url", queue_url,
                "--receipt-handle", m["ReceiptHandle"],
            )
    return out


def test_cli_cp_fires_object_created_put():
    bucket = f"cli-evpat-{secrets.token_hex(4)}"
    queue_url = _setup(bucket, ["s3:ObjectCreated:Put"])
    tmp = _temp_file_with("world")
    try:
        run_aws("s3", "cp", tmp, f"s3://{bucket}/hello.txt")
        records = _drain(queue_url)
        assert len(records) == 1
        assert records[0]["eventName"] == "s3:ObjectCreated:Put"
        assert records[0]["s3"]["object"]["key"] == "hello.txt"
    finally:
        os.unlink(tmp)
        run_aws("sqs", "delete-queue", "--queue-url", queue_url, check=False)
        run_aws("s3", "rm", f"s3://{bucket}/hello.txt", check=False)
        run_aws("s3", "rb", f"s3://{bucket}", check=False)


def test_cli_rm_fires_object_removed_delete():
    bucket = f"cli-evdel-{secrets.token_hex(4)}"
    queue_url = _setup(bucket, ["s3:ObjectRemoved:Delete"])
    tmp = _temp_file_with("v")
    try:
        run_aws("s3", "cp", tmp, f"s3://{bucket}/k")
        run_aws("s3", "rm", f"s3://{bucket}/k")
        records = _drain(queue_url)
        assert len(records) == 1
        assert records[0]["eventName"] == "s3:ObjectRemoved:Delete"
        assert records[0]["s3"]["object"]["key"] == "k"
    finally:
        os.unlink(tmp)
        run_aws("sqs", "delete-queue", "--queue-url", queue_url, check=False)
        run_aws("s3", "rb", f"s3://{bucket}", check=False)
