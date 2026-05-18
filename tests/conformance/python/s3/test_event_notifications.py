"""S3 → SQS event-notification conformance — v0.3.4.

These tests verify that S3 actually fires events to configured SQS
queues when objects are created or removed. The wire surface
(PutBucketNotificationConfiguration) has been there since M11; this
suite covers the dispatch layer that landed in v0.3.4.
"""

from __future__ import annotations

import json
import secrets

import boto3
import pytest
from botocore.config import Config

from conftest import best_effort_delete_bucket, endpoint, empty_bucket


def _make_sqs():
    return boto3.client(
        "sqs",
        endpoint_url=endpoint(),
        region_name="us-east-1",
        aws_access_key_id="test",
        aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 1}),
    )


def _setup(s3, bucket_name: str, events: list[str], filter_rules: list[dict] | None = None):
    """Create the bucket + a uniquely-named SQS queue, attach a
    QueueConfiguration that targets the queue, return the queue URL.
    Caller is responsible for empty+delete_bucket and SQS delete."""
    s3.create_bucket(Bucket=bucket_name)
    sqs = _make_sqs()
    queue_name = f"q_{secrets.token_hex(4)}"
    queue_url = sqs.create_queue(QueueName=queue_name)["QueueUrl"]
    queue_arn = f"arn:aws:sqs:us-east-1:000000000000:{queue_name}"
    cfg = {
        "QueueConfigurations": [{
            "Id": "test-config",
            "QueueArn": queue_arn,
            "Events": events,
        }],
    }
    if filter_rules is not None:
        cfg["QueueConfigurations"][0]["Filter"] = {"Key": {"FilterRules": filter_rules}}
    s3.put_bucket_notification_configuration(
        Bucket=bucket_name, NotificationConfiguration=cfg,
    )
    return sqs, queue_url


def _drain(sqs, queue_url: str, max_wait_s: float = 5.0) -> list[dict]:
    """Receive every message currently in the queue, parse Records,
    flatten into a single list."""
    import time
    deadline = time.time() + max_wait_s
    out: list[dict] = []
    while time.time() < deadline:
        resp = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=10, WaitTimeSeconds=1)
        msgs = resp.get("Messages", [])
        if not msgs:
            if out:
                return out
            continue
        for m in msgs:
            body = json.loads(m["Body"])
            for rec in body.get("Records", []):
                out.append(rec)
            sqs.delete_message(QueueUrl=queue_url, ReceiptHandle=m["ReceiptHandle"])
    return out


def test_put_object_fires_object_created_put(s3, bucket_name):
    sqs, queue_url = _setup(s3, bucket_name, ["s3:ObjectCreated:Put"])
    try:
        s3.put_object(Bucket=bucket_name, Key="hello.txt", Body=b"world")
        records = _drain(sqs, queue_url)
        assert len(records) == 1
        rec = records[0]
        assert rec["eventName"] == "s3:ObjectCreated:Put"
        assert rec["eventSource"] == "aws:s3"
        assert rec["s3"]["bucket"]["name"] == bucket_name
        assert rec["s3"]["object"]["key"] == "hello.txt"
        assert rec["s3"]["object"]["size"] == 5
    finally:
        sqs.delete_queue(QueueUrl=queue_url)
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_copy_object_fires_object_created_copy(s3, bucket_name):
    sqs, queue_url = _setup(s3, bucket_name, ["s3:ObjectCreated:Copy"])
    try:
        s3.put_object(Bucket=bucket_name, Key="src.txt", Body=b"hi")
        # Drain the PutObject's would-be event (only :Copy is subscribed, so
        # this shouldn't fire — confirm by asserting the post-Copy stream
        # has exactly one event).
        s3.copy_object(
            Bucket=bucket_name,
            Key="dst.txt",
            CopySource={"Bucket": bucket_name, "Key": "src.txt"},
        )
        records = _drain(sqs, queue_url)
        assert len(records) == 1
        assert records[0]["eventName"] == "s3:ObjectCreated:Copy"
        assert records[0]["s3"]["object"]["key"] == "dst.txt"
    finally:
        sqs.delete_queue(QueueUrl=queue_url)
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_delete_object_fires_object_removed_delete(s3, bucket_name):
    sqs, queue_url = _setup(s3, bucket_name, ["s3:ObjectRemoved:Delete"])
    try:
        s3.put_object(Bucket=bucket_name, Key="x", Body=b"y")
        s3.delete_object(Bucket=bucket_name, Key="x")
        records = _drain(sqs, queue_url)
        assert len(records) == 1
        assert records[0]["eventName"] == "s3:ObjectRemoved:Delete"
        assert records[0]["s3"]["object"]["key"] == "x"
    finally:
        sqs.delete_queue(QueueUrl=queue_url)
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_delete_marker_fires_delete_marker_created(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    s3.put_bucket_versioning(
        Bucket=bucket_name, VersioningConfiguration={"Status": "Enabled"}
    )
    sqs = _make_sqs()
    queue_name = f"q_{secrets.token_hex(4)}"
    queue_url = sqs.create_queue(QueueName=queue_name)["QueueUrl"]
    queue_arn = f"arn:aws:sqs:us-east-1:000000000000:{queue_name}"
    s3.put_bucket_notification_configuration(
        Bucket=bucket_name,
        NotificationConfiguration={
            "QueueConfigurations": [{
                "QueueArn": queue_arn,
                "Events": ["s3:ObjectRemoved:*"],
            }],
        },
    )
    try:
        s3.put_object(Bucket=bucket_name, Key="k", Body=b"v")
        # Delete without versionId on a versioned bucket creates a delete marker.
        s3.delete_object(Bucket=bucket_name, Key="k")
        records = _drain(sqs, queue_url)
        assert len(records) == 1
        assert records[0]["eventName"] == "s3:ObjectRemoved:DeleteMarkerCreated"
    finally:
        sqs.delete_queue(QueueUrl=queue_url)
        # Versioned bucket cleanup.
        from conftest import drain_versions
        drain_versions(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_delete_objects_fires_per_entry(s3, bucket_name):
    sqs, queue_url = _setup(s3, bucket_name, ["s3:ObjectRemoved:*"])
    try:
        for k in ["a", "b", "c"]:
            s3.put_object(Bucket=bucket_name, Key=k, Body=b"x")
        s3.delete_objects(
            Bucket=bucket_name,
            Delete={"Objects": [{"Key": "a"}, {"Key": "b"}, {"Key": "c"}]},
        )
        records = _drain(sqs, queue_url)
        keys = sorted(r["s3"]["object"]["key"] for r in records)
        assert keys == ["a", "b", "c"]
        assert all(r["eventName"] == "s3:ObjectRemoved:Delete" for r in records)
    finally:
        sqs.delete_queue(QueueUrl=queue_url)
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_prefix_filter_limits_dispatch(s3, bucket_name):
    sqs, queue_url = _setup(
        s3, bucket_name,
        ["s3:ObjectCreated:Put"],
        filter_rules=[{"Name": "prefix", "Value": "images/"}],
    )
    try:
        s3.put_object(Bucket=bucket_name, Key="images/cat.jpg", Body=b"x")
        s3.put_object(Bucket=bucket_name, Key="docs/readme.md", Body=b"y")
        records = _drain(sqs, queue_url)
        assert len(records) == 1
        assert records[0]["s3"]["object"]["key"] == "images/cat.jpg"
    finally:
        sqs.delete_queue(QueueUrl=queue_url)
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_suffix_filter_limits_dispatch(s3, bucket_name):
    sqs, queue_url = _setup(
        s3, bucket_name,
        ["s3:ObjectCreated:Put"],
        filter_rules=[{"Name": "suffix", "Value": ".jpg"}],
    )
    try:
        s3.put_object(Bucket=bucket_name, Key="cat.jpg", Body=b"x")
        s3.put_object(Bucket=bucket_name, Key="cat.png", Body=b"y")
        records = _drain(sqs, queue_url)
        assert len(records) == 1
        assert records[0]["s3"]["object"]["key"] == "cat.jpg"
    finally:
        sqs.delete_queue(QueueUrl=queue_url)
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_wildcard_event_fires_for_put_and_copy(s3, bucket_name):
    sqs, queue_url = _setup(s3, bucket_name, ["s3:ObjectCreated:*"])
    try:
        s3.put_object(Bucket=bucket_name, Key="a", Body=b"x")
        s3.copy_object(
            Bucket=bucket_name,
            Key="b",
            CopySource={"Bucket": bucket_name, "Key": "a"},
        )
        records = _drain(sqs, queue_url)
        names = sorted(r["eventName"] for r in records)
        assert names == ["s3:ObjectCreated:Copy", "s3:ObjectCreated:Put"]
    finally:
        sqs.delete_queue(QueueUrl=queue_url)
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_event_name_mismatch_does_not_fire(s3, bucket_name):
    """Notification config subscribes to Delete only — Put should not fire."""
    sqs, queue_url = _setup(s3, bucket_name, ["s3:ObjectRemoved:Delete"])
    try:
        s3.put_object(Bucket=bucket_name, Key="k", Body=b"v")
        records = _drain(sqs, queue_url, max_wait_s=2.0)
        assert len(records) == 0
    finally:
        sqs.delete_queue(QueueUrl=queue_url)
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_no_notification_config_does_not_fire(s3, bucket_name):
    """Bucket with no notification config — PutObject is a no-op on the
    dispatcher path."""
    s3.create_bucket(Bucket=bucket_name)
    sqs = _make_sqs()
    queue_name = f"q_{secrets.token_hex(4)}"
    queue_url = sqs.create_queue(QueueName=queue_name)["QueueUrl"]
    try:
        s3.put_object(Bucket=bucket_name, Key="k", Body=b"v")
        records = _drain(sqs, queue_url, max_wait_s=2.0)
        assert len(records) == 0
    finally:
        sqs.delete_queue(QueueUrl=queue_url)
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)
