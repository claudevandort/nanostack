"""SQS tag conformance — Phase 5 of v0.3.0.

TagQueue / UntagQueue / ListQueueTags.
"""

from __future__ import annotations

import uuid

import boto3
import botocore.exceptions
import pytest
from botocore.config import Config

from conftest import endpoint


def _make_sqs():
    return boto3.client(
        "sqs",
        endpoint_url=endpoint(),
        region_name="us-east-1",
        aws_access_key_id="test",
        aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 1}),
    )


@pytest.fixture
def sqs():
    return _make_sqs()


def _unique(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


@pytest.fixture
def queue_url(sqs):
    name = _unique("tag")
    url = sqs.create_queue(QueueName=name)["QueueUrl"]
    yield url
    try:
        sqs.delete_queue(QueueUrl=url)
    except botocore.exceptions.ClientError:
        pass


def test_tag_queue_round_trip(sqs, queue_url):
    sqs.tag_queue(QueueUrl=queue_url, Tags={"env": "dev", "owner": "team-orders"})
    out = sqs.list_queue_tags(QueueUrl=queue_url)
    assert out["Tags"] == {"env": "dev", "owner": "team-orders"}


def test_tag_queue_overwrites_existing(sqs, queue_url):
    sqs.tag_queue(QueueUrl=queue_url, Tags={"env": "dev"})
    sqs.tag_queue(QueueUrl=queue_url, Tags={"env": "prod"})
    out = sqs.list_queue_tags(QueueUrl=queue_url)
    assert out["Tags"]["env"] == "prod"


def test_untag_queue_removes_keys(sqs, queue_url):
    sqs.tag_queue(QueueUrl=queue_url, Tags={"a": "1", "b": "2", "c": "3"})
    sqs.untag_queue(QueueUrl=queue_url, TagKeys=["b"])
    out = sqs.list_queue_tags(QueueUrl=queue_url)
    assert set(out["Tags"].keys()) == {"a", "c"}


def test_list_tags_on_untagged_queue(sqs, queue_url):
    out = sqs.list_queue_tags(QueueUrl=queue_url)
    # boto3 returns an empty dict (or no "Tags" key) for untagged queues.
    assert out.get("Tags", {}) == {}
