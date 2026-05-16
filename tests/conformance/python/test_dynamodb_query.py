"""DynamoDB Query conformance (M15-query, Phase 5)."""

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
def events_table(ddb, request):
    name = _unique("query", request)
    ddb.create_table(
        TableName=name,
        KeySchema=[
            {"AttributeName": "user", "KeyType": "HASH"},
            {"AttributeName": "ts", "KeyType": "RANGE"},
        ],
        AttributeDefinitions=[
            {"AttributeName": "user", "AttributeType": "S"},
            {"AttributeName": "ts", "AttributeType": "N"},
        ],
        BillingMode="PAY_PER_REQUEST",
    )
    # Seed: alice has 5 events at ts=100..500, bob has 1 at ts=999
    for ts in [100, 200, 300, 400, 500]:
        ddb.put_item(TableName=name, Item={"user": {"S": "alice"}, "ts": {"N": str(ts)}, "kind": {"S": "view"}})
    ddb.put_item(TableName=name, Item={"user": {"S": "bob"}, "ts": {"N": "999"}, "kind": {"S": "click"}})
    yield name
    try:
        ddb.delete_table(TableName=name)
    except botocore.exceptions.ClientError:
        pass


def test_query_pk_only(ddb, events_table):
    out = ddb.query(
        TableName=events_table,
        KeyConditionExpression="#u = :u",
        ExpressionAttributeNames={"#u": "user"},
        ExpressionAttributeValues={":u": {"S": "alice"}},
    )
    assert out["Count"] == 5
    assert all(it["user"]["S"] == "alice" for it in out["Items"])


def test_query_pk_excludes_other_partition(ddb, events_table):
    out = ddb.query(
        TableName=events_table,
        KeyConditionExpression="#u = :u",
        ExpressionAttributeNames={"#u": "user"},
        ExpressionAttributeValues={":u": {"S": "bob"}},
    )
    assert out["Count"] == 1
    assert out["Items"][0]["user"]["S"] == "bob"


def test_query_pk_and_sk_eq(ddb, events_table):
    out = ddb.query(
        TableName=events_table,
        KeyConditionExpression="#u = :u AND ts = :t",
        ExpressionAttributeNames={"#u": "user"},
        ExpressionAttributeValues={":u": {"S": "alice"}, ":t": {"N": "300"}},
    )
    assert out["Count"] == 1
    assert out["Items"][0]["ts"]["N"] == "300"


def test_query_pk_and_sk_between(ddb, events_table):
    out = ddb.query(
        TableName=events_table,
        KeyConditionExpression="#u = :u AND ts BETWEEN :a AND :b",
        ExpressionAttributeNames={"#u": "user"},
        ExpressionAttributeValues={":u": {"S": "alice"}, ":a": {"N": "150"}, ":b": {"N": "350"}},
    )
    tss = sorted(it["ts"]["N"] for it in out["Items"])
    assert tss == ["200", "300"]


def test_query_pk_and_sk_gt(ddb, events_table):
    out = ddb.query(
        TableName=events_table,
        KeyConditionExpression="#u = :u AND ts > :t",
        ExpressionAttributeNames={"#u": "user"},
        ExpressionAttributeValues={":u": {"S": "alice"}, ":t": {"N": "250"}},
    )
    tss = sorted(it["ts"]["N"] for it in out["Items"])
    assert tss == ["300", "400", "500"]


def test_query_limit(ddb, events_table):
    out = ddb.query(
        TableName=events_table,
        KeyConditionExpression="#u = :u",
        ExpressionAttributeNames={"#u": "user"},
        ExpressionAttributeValues={":u": {"S": "alice"}},
        Limit=2,
    )
    assert out["Count"] == 2
    assert "LastEvaluatedKey" in out


def test_query_scan_index_forward_false_descends(ddb, events_table):
    out = ddb.query(
        TableName=events_table,
        KeyConditionExpression="#u = :u",
        ExpressionAttributeNames={"#u": "user"},
        ExpressionAttributeValues={":u": {"S": "alice"}},
        ScanIndexForward=False,
        Limit=2,
    )
    tss = [it["ts"]["N"] for it in out["Items"]]
    assert tss[0] > tss[1]  # descending


def test_query_filter_expression(ddb, events_table):
    """FilterExpression runs after the key match. Doesn't reduce ScannedCount."""
    out = ddb.query(
        TableName=events_table,
        KeyConditionExpression="#u = :u",
        FilterExpression="kind = :k",
        ExpressionAttributeNames={"#u": "user"},
        ExpressionAttributeValues={":u": {"S": "alice"}, ":k": {"S": "view"}},
    )
    assert out["Count"] == 5  # all alice items have kind=view


def test_query_pagination_roundtrip(ddb, events_table):
    """Page through alice's events 2 at a time."""
    first = ddb.query(
        TableName=events_table,
        KeyConditionExpression="#u = :u",
        ExpressionAttributeNames={"#u": "user"},
        ExpressionAttributeValues={":u": {"S": "alice"}},
        Limit=2,
    )
    assert first["Count"] == 2
    cursor = first["LastEvaluatedKey"]

    second = ddb.query(
        TableName=events_table,
        KeyConditionExpression="#u = :u",
        ExpressionAttributeNames={"#u": "user"},
        ExpressionAttributeValues={":u": {"S": "alice"}},
        Limit=2,
        ExclusiveStartKey=cursor,
    )
    assert second["Count"] == 2

    # Items shouldn't overlap.
    first_tss = {it["ts"]["N"] for it in first["Items"]}
    second_tss = {it["ts"]["N"] for it in second["Items"]}
    assert first_tss.isdisjoint(second_tss)


def test_query_no_match_returns_empty(ddb, events_table):
    out = ddb.query(
        TableName=events_table,
        KeyConditionExpression="#u = :u",
        ExpressionAttributeNames={"#u": "user"},
        ExpressionAttributeValues={":u": {"S": "nobody"}},
    )
    assert out["Count"] == 0
    assert out["Items"] == []


def test_query_table_not_found(ddb):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.query(
            TableName="no-such-table-query",
            KeyConditionExpression="pk = :v",
            ExpressionAttributeValues={":v": {"S": "x"}},
        )
    assert ei.value.response["Error"]["Code"] == "ResourceNotFoundException"


def test_query_begins_with_sk(ddb, request):
    """begins_with on string sort key."""
    name = _unique("qbw", request)
    ddb = _make_ddb()
    ddb.create_table(
        TableName=name,
        KeySchema=[
            {"AttributeName": "pk", "KeyType": "HASH"},
            {"AttributeName": "sk", "KeyType": "RANGE"},
        ],
        AttributeDefinitions=[
            {"AttributeName": "pk", "AttributeType": "S"},
            {"AttributeName": "sk", "AttributeType": "S"},
        ],
        BillingMode="PAY_PER_REQUEST",
    )
    try:
        for sk in ["alpha", "alpine", "beta", "alabaster"]:
            ddb.put_item(TableName=name, Item={"pk": {"S": "p"}, "sk": {"S": sk}})

        out = ddb.query(
            TableName=name,
            KeyConditionExpression="pk = :p AND begins_with(sk, :prefix)",
            ExpressionAttributeValues={":p": {"S": "p"}, ":prefix": {"S": "al"}},
        )
        sks = sorted(it["sk"]["S"] for it in out["Items"])
        assert sks == ["alabaster", "alpha", "alpine"]
    finally:
        try:
            ddb.delete_table(TableName=name)
        except botocore.exceptions.ClientError:
            pass
