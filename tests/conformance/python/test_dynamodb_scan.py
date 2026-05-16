"""DynamoDB Scan conformance (M15-scan, Phase 6)."""

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
def seeded_table(ddb, request):
    name = _unique("scan", request)
    ddb.create_table(
        TableName=name,
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    for i in range(5):
        ddb.put_item(TableName=name, Item={"id": {"S": f"item-{i}"}, "n": {"N": str(i)}})
    yield name
    try:
        ddb.delete_table(TableName=name)
    except botocore.exceptions.ClientError:
        pass


def test_scan_returns_all_items(ddb, seeded_table):
    out = ddb.scan(TableName=seeded_table)
    assert out["Count"] == 5
    assert out["ScannedCount"] == 5


def test_scan_with_filter_expression(ddb, seeded_table):
    """FilterExpression doesn't reduce ScannedCount, only Count."""
    out = ddb.scan(
        TableName=seeded_table,
        FilterExpression="n > :t",
        ExpressionAttributeValues={":t": {"N": "2"}},
    )
    assert out["Count"] == 2  # items with n=3, n=4
    assert out["ScannedCount"] == 5


def test_scan_with_limit_and_pagination(ddb, seeded_table):
    page1 = ddb.scan(TableName=seeded_table, Limit=2)
    assert page1["Count"] == 2
    assert "LastEvaluatedKey" in page1

    page2 = ddb.scan(
        TableName=seeded_table,
        Limit=2,
        ExclusiveStartKey=page1["LastEvaluatedKey"],
    )
    # Should pick up where page1 left off.
    page1_ids = {it["id"]["S"] for it in page1["Items"]}
    page2_ids = {it["id"]["S"] for it in page2["Items"]}
    assert page1_ids.isdisjoint(page2_ids)


def test_scan_parallel_segments_rejected(ddb, seeded_table):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.scan(TableName=seeded_table, TotalSegments=4, Segment=0)
    assert ei.value.response["Error"]["Code"] == "ValidationException"
    assert "parallel" in ei.value.response["Error"]["Message"].lower()


def test_scan_total_segments_one_ok(ddb, seeded_table):
    """TotalSegments=1 is the single-segment case; should work."""
    out = ddb.scan(TableName=seeded_table, TotalSegments=1, Segment=0)
    assert out["Count"] == 5


def test_scan_missing_table(ddb):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.scan(TableName="no-such-table-scan")
    assert ei.value.response["Error"]["Code"] == "ResourceNotFoundException"


def test_scan_empty_table(ddb, request):
    name = _unique("scan-empty", request)
    ddb.create_table(
        TableName=name,
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    try:
        out = ddb.scan(TableName=name)
        assert out["Count"] == 0
        assert out["Items"] == []
        assert "LastEvaluatedKey" not in out
    finally:
        try:
            ddb.delete_table(TableName=name)
        except botocore.exceptions.ClientError:
            pass
