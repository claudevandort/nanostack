"""DynamoDB GSI/LSI Query conformance (M15-gsi, Phase 8)."""

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
def gsi_table(ddb, request):
    name = _unique("gsi", request)
    ddb.create_table(
        TableName=name,
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        AttributeDefinitions=[
            {"AttributeName": "id", "AttributeType": "S"},
            {"AttributeName": "category", "AttributeType": "S"},
            {"AttributeName": "ts", "AttributeType": "N"},
        ],
        GlobalSecondaryIndexes=[{
            "IndexName": "by-category",
            "KeySchema": [
                {"AttributeName": "category", "KeyType": "HASH"},
                {"AttributeName": "ts", "KeyType": "RANGE"},
            ],
            "Projection": {"ProjectionType": "ALL"},
        }],
        BillingMode="PAY_PER_REQUEST",
    )
    # Seed
    items = [
        {"id": {"S": "p1"}, "category": {"S": "books"}, "ts": {"N": "100"}, "price": {"N": "15"}},
        {"id": {"S": "p2"}, "category": {"S": "books"}, "ts": {"N": "200"}, "price": {"N": "25"}},
        {"id": {"S": "p3"}, "category": {"S": "music"}, "ts": {"N": "300"}, "price": {"N": "10"}},
        {"id": {"S": "p4"}, "category": {"S": "books"}, "ts": {"N": "400"}, "price": {"N": "30"}},
    ]
    for it in items:
        ddb.put_item(TableName=name, Item=it)
    yield name
    try:
        ddb.delete_table(TableName=name)
    except botocore.exceptions.ClientError:
        pass


def test_gsi_query_returns_partition_items(ddb, gsi_table):
    out = ddb.query(
        TableName=gsi_table,
        IndexName="by-category",
        KeyConditionExpression="category = :c",
        ExpressionAttributeValues={":c": {"S": "books"}},
    )
    assert out["Count"] == 3
    assert all(it["category"]["S"] == "books" for it in out["Items"])


def test_gsi_query_sort_key_range(ddb, gsi_table):
    out = ddb.query(
        TableName=gsi_table,
        IndexName="by-category",
        KeyConditionExpression="category = :c AND ts BETWEEN :a AND :b",
        ExpressionAttributeValues={":c": {"S": "books"}, ":a": {"N": "150"}, ":b": {"N": "350"}},
    )
    tss = sorted(it["ts"]["N"] for it in out["Items"])
    assert tss == ["200"]


def test_gsi_query_sort_descending(ddb, gsi_table):
    out = ddb.query(
        TableName=gsi_table,
        IndexName="by-category",
        KeyConditionExpression="category = :c",
        ExpressionAttributeValues={":c": {"S": "books"}},
        ScanIndexForward=False,
    )
    tss = [it["ts"]["N"] for it in out["Items"]]
    assert tss == sorted(tss, reverse=True)


def test_gsi_query_unknown_index(ddb, gsi_table):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.query(
            TableName=gsi_table,
            IndexName="nope",
            KeyConditionExpression="category = :c",
            ExpressionAttributeValues={":c": {"S": "books"}},
        )
    assert ei.value.response["Error"]["Code"] == "ValidationException"


def test_gsi_query_skips_items_without_index_key(ddb, request):
    """Items that don't have the GSI's PK attribute are excluded from index."""
    name = _unique("gsi-sparse", request)
    ddb.create_table(
        TableName=name,
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        AttributeDefinitions=[
            {"AttributeName": "id", "AttributeType": "S"},
            {"AttributeName": "tag", "AttributeType": "S"},
        ],
        GlobalSecondaryIndexes=[{
            "IndexName": "by-tag",
            "KeySchema": [{"AttributeName": "tag", "KeyType": "HASH"}],
            "Projection": {"ProjectionType": "ALL"},
        }],
        BillingMode="PAY_PER_REQUEST",
    )
    try:
        ddb.put_item(TableName=name, Item={"id": {"S": "k1"}, "tag": {"S": "red"}})
        ddb.put_item(TableName=name, Item={"id": {"S": "k2"}})  # no tag attribute
        out = ddb.query(
            TableName=name,
            IndexName="by-tag",
            KeyConditionExpression="tag = :t",
            ExpressionAttributeValues={":t": {"S": "red"}},
        )
        assert out["Count"] == 1
    finally:
        try:
            ddb.delete_table(TableName=name)
        except botocore.exceptions.ClientError:
            pass


def test_gsi_query_keys_only_projection(ddb, request):
    """KEYS_ONLY projection returns base + index keys, but not other attrs."""
    name = _unique("gsi-keys", request)
    ddb.create_table(
        TableName=name,
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        AttributeDefinitions=[
            {"AttributeName": "id", "AttributeType": "S"},
            {"AttributeName": "tag", "AttributeType": "S"},
        ],
        GlobalSecondaryIndexes=[{
            "IndexName": "by-tag",
            "KeySchema": [{"AttributeName": "tag", "KeyType": "HASH"}],
            "Projection": {"ProjectionType": "KEYS_ONLY"},
        }],
        BillingMode="PAY_PER_REQUEST",
    )
    try:
        ddb.put_item(TableName=name, Item={"id": {"S": "k1"}, "tag": {"S": "red"}, "secret": {"S": "hidden"}})
        out = ddb.query(
            TableName=name,
            IndexName="by-tag",
            KeyConditionExpression="tag = :t",
            ExpressionAttributeValues={":t": {"S": "red"}},
        )
        item = out["Items"][0]
        assert "id" in item
        assert "tag" in item
        assert "secret" not in item, f"KEYS_ONLY shouldn't surface 'secret'; got {item}"
    finally:
        try:
            ddb.delete_table(TableName=name)
        except botocore.exceptions.ClientError:
            pass


def test_gsi_query_include_projection(ddb, request):
    """INCLUDE projection: base + index keys + listed non-key attrs."""
    name = _unique("gsi-inc", request)
    ddb.create_table(
        TableName=name,
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        AttributeDefinitions=[
            {"AttributeName": "id", "AttributeType": "S"},
            {"AttributeName": "tag", "AttributeType": "S"},
        ],
        GlobalSecondaryIndexes=[{
            "IndexName": "by-tag",
            "KeySchema": [{"AttributeName": "tag", "KeyType": "HASH"}],
            "Projection": {"ProjectionType": "INCLUDE", "NonKeyAttributes": ["price"]},
        }],
        BillingMode="PAY_PER_REQUEST",
    )
    try:
        ddb.put_item(TableName=name, Item={
            "id": {"S": "k1"}, "tag": {"S": "red"}, "price": {"N": "5"}, "secret": {"S": "hidden"}
        })
        out = ddb.query(
            TableName=name,
            IndexName="by-tag",
            KeyConditionExpression="tag = :t",
            ExpressionAttributeValues={":t": {"S": "red"}},
        )
        item = out["Items"][0]
        assert "price" in item
        assert "secret" not in item
    finally:
        try:
            ddb.delete_table(TableName=name)
        except botocore.exceptions.ClientError:
            pass


def test_gsi_query_with_filter_expression(ddb, gsi_table):
    """FilterExpression runs against the projected (full) item."""
    out = ddb.query(
        TableName=gsi_table,
        IndexName="by-category",
        KeyConditionExpression="category = :c",
        FilterExpression="price > :min",
        ExpressionAttributeValues={":c": {"S": "books"}, ":min": {"N": "20"}},
    )
    assert out["Count"] == 2  # p2 + p4 have price > 20
    assert out["ScannedCount"] >= 3


def test_gsi_lsi_definition_then_query(ddb, request):
    """LSI: same PK as base, different SK. Query routes correctly."""
    name = _unique("lsi", request)
    ddb.create_table(
        TableName=name,
        KeySchema=[
            {"AttributeName": "pk", "KeyType": "HASH"},
            {"AttributeName": "sk", "KeyType": "RANGE"},
        ],
        AttributeDefinitions=[
            {"AttributeName": "pk", "AttributeType": "S"},
            {"AttributeName": "sk", "AttributeType": "S"},
            {"AttributeName": "lsi_sk", "AttributeType": "N"},
        ],
        LocalSecondaryIndexes=[{
            "IndexName": "by-num",
            "KeySchema": [
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "lsi_sk", "KeyType": "RANGE"},
            ],
            "Projection": {"ProjectionType": "ALL"},
        }],
        BillingMode="PAY_PER_REQUEST",
    )
    try:
        for i, lsi in enumerate([300, 100, 200], start=1):
            ddb.put_item(TableName=name, Item={
                "pk": {"S": "p"}, "sk": {"S": f"s{i}"}, "lsi_sk": {"N": str(lsi)},
            })
        out = ddb.query(
            TableName=name,
            IndexName="by-num",
            KeyConditionExpression="pk = :p AND lsi_sk > :n",
            ExpressionAttributeValues={":p": {"S": "p"}, ":n": {"N": "150"}},
        )
        lsis = sorted(int(it["lsi_sk"]["N"]) for it in out["Items"])
        assert lsis == [200, 300]
    finally:
        try:
            ddb.delete_table(TableName=name)
        except botocore.exceptions.ClientError:
            pass
