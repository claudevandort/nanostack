"""DynamoDB BatchGetItem + BatchWriteItem conformance (M15-batch, Phase 7)."""

from __future__ import annotations

import pytest
import boto3
import botocore.exceptions
from botocore.config import Config

from conftest import endpoint


def _make_ddb():
    return boto3.client(
        "dynamodb",
        endpoint_url=endpoint(),
        region_name="us-east-1",
        aws_access_key_id="test",
        aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 1}),
    )


@pytest.fixture
def ddb():
    return _make_ddb()


def _unique(prefix, request):
    return f"{prefix}-{request.node.name.replace('[', '-').replace(']', '')[:80]}"


@pytest.fixture
def two_tables(ddb, request):
    a = _unique("batchA", request)
    b = _unique("batchB", request)
    for name in (a, b):
        ddb.create_table(
            TableName=name,
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
    yield (a, b)
    for name in (a, b):
        try:
            ddb.delete_table(TableName=name)
        except botocore.exceptions.ClientError:
            pass


def test_batch_write_then_batch_get_single_table(ddb, two_tables):
    a, _ = two_tables
    ddb.batch_write_item(RequestItems={
        a: [
            {"PutRequest": {"Item": {"id": {"S": "k1"}, "v": {"S": "one"}}}},
            {"PutRequest": {"Item": {"id": {"S": "k2"}, "v": {"S": "two"}}}},
        ]
    })
    out = ddb.batch_get_item(RequestItems={
        a: {"Keys": [{"id": {"S": "k1"}}, {"id": {"S": "k2"}}]}
    })
    items = out["Responses"][a]
    assert {it["id"]["S"] for it in items} == {"k1", "k2"}


def test_batch_write_cross_table(ddb, two_tables):
    a, b = two_tables
    ddb.batch_write_item(RequestItems={
        a: [{"PutRequest": {"Item": {"id": {"S": "k1"}, "src": {"S": "A"}}}}],
        b: [{"PutRequest": {"Item": {"id": {"S": "k1"}, "src": {"S": "B"}}}}],
    })
    out_a = ddb.get_item(TableName=a, Key={"id": {"S": "k1"}})
    out_b = ddb.get_item(TableName=b, Key={"id": {"S": "k1"}})
    assert out_a["Item"]["src"] == {"S": "A"}
    assert out_b["Item"]["src"] == {"S": "B"}


def test_batch_write_with_delete(ddb, two_tables):
    a, _ = two_tables
    ddb.put_item(TableName=a, Item={"id": {"S": "doomed"}, "v": {"S": "x"}})
    ddb.batch_write_item(RequestItems={
        a: [{"DeleteRequest": {"Key": {"id": {"S": "doomed"}}}}]
    })
    out = ddb.get_item(TableName=a, Key={"id": {"S": "doomed"}})
    assert "Item" not in out


def test_batch_get_missing_key_returns_only_found(ddb, two_tables):
    a, _ = two_tables
    ddb.put_item(TableName=a, Item={"id": {"S": "exists"}, "v": {"S": "x"}})
    out = ddb.batch_get_item(RequestItems={
        a: {"Keys": [{"id": {"S": "exists"}}, {"id": {"S": "missing"}}]}
    })
    items = out["Responses"][a]
    assert len(items) == 1
    assert items[0]["id"]["S"] == "exists"


def test_batch_write_over_cap_rejected(ddb, two_tables):
    a, _ = two_tables
    # 26 puts → over the 25-cap.
    requests = [{"PutRequest": {"Item": {"id": {"S": f"k{i}"}}}} for i in range(26)]
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.batch_write_item(RequestItems={a: requests})
    assert ei.value.response["Error"]["Code"] == "ValidationException"


def test_batch_get_unprocessed_keys_always_empty(ddb, two_tables):
    """v1 stance: nanostack succeeds or fails the whole batch, never partial."""
    a, _ = two_tables
    ddb.put_item(TableName=a, Item={"id": {"S": "k"}, "v": {"S": "x"}})
    out = ddb.batch_get_item(RequestItems={a: {"Keys": [{"id": {"S": "k"}}]}})
    assert out.get("UnprocessedKeys") == {}
