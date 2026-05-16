"""DynamoDB item-CRUD conformance (M15-items, Phase 3).

GetItem / PutItem / DeleteItem without expressions. ReturnValues
NONE / ALL_OLD only — UPDATED_* and conditional updates land in
Phase 4 (M15-expressions).
"""

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


def _unique_name(prefix: str, request) -> str:
    safe = request.node.name.replace("[", "-").replace("]", "").replace(":", "_")[:80]
    return f"{prefix}-{safe}"


@pytest.fixture
def hash_table(ddb, request):
    name = _unique_name("items-hash", request)
    ddb.create_table(
        TableName=name,
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    yield name
    try:
        ddb.delete_table(TableName=name)
    except botocore.exceptions.ClientError:
        pass


@pytest.fixture
def composite_table(ddb, request):
    name = _unique_name("items-comp", request)
    ddb.create_table(
        TableName=name,
        KeySchema=[
            {"AttributeName": "pk", "KeyType": "HASH"},
            {"AttributeName": "sk", "KeyType": "RANGE"},
        ],
        AttributeDefinitions=[
            {"AttributeName": "pk", "AttributeType": "S"},
            {"AttributeName": "sk", "AttributeType": "N"},
        ],
        BillingMode="PAY_PER_REQUEST",
    )
    yield name
    try:
        ddb.delete_table(TableName=name)
    except botocore.exceptions.ClientError:
        pass


# ---------------------------------------------------------------------------
# PutItem + GetItem round-trip

def test_put_get_roundtrip(ddb, hash_table):
    ddb.put_item(TableName=hash_table, Item={
        "id": {"S": "k1"},
        "name": {"S": "Bob"},
        "age": {"N": "42"},
    })
    out = ddb.get_item(TableName=hash_table, Key={"id": {"S": "k1"}})
    assert out["Item"]["name"] == {"S": "Bob"}
    assert out["Item"]["age"] == {"N": "42"}


def test_get_missing_returns_no_item_key(ddb, hash_table):
    out = ddb.get_item(TableName=hash_table, Key={"id": {"S": "absent"}})
    assert "Item" not in out


def test_put_overwrites_existing(ddb, hash_table):
    ddb.put_item(TableName=hash_table, Item={"id": {"S": "k1"}, "v": {"S": "first"}})
    ddb.put_item(TableName=hash_table, Item={"id": {"S": "k1"}, "v": {"S": "second"}})
    out = ddb.get_item(TableName=hash_table, Key={"id": {"S": "k1"}})
    assert out["Item"]["v"] == {"S": "second"}


def test_put_with_return_values_all_old(ddb, hash_table):
    ddb.put_item(TableName=hash_table, Item={"id": {"S": "k1"}, "v": {"S": "first"}})
    out = ddb.put_item(
        TableName=hash_table,
        Item={"id": {"S": "k1"}, "v": {"S": "second"}},
        ReturnValues="ALL_OLD",
    )
    assert out.get("Attributes") == {"id": {"S": "k1"}, "v": {"S": "first"}}


def test_put_new_with_return_values_all_old_returns_no_attributes(ddb, hash_table):
    """ALL_OLD on a fresh key should NOT include the Attributes field."""
    out = ddb.put_item(
        TableName=hash_table,
        Item={"id": {"S": "fresh"}, "v": {"S": "x"}},
        ReturnValues="ALL_OLD",
    )
    assert "Attributes" not in out


# ---------------------------------------------------------------------------
# Composite-key (HASH + RANGE)

def test_composite_key_distinguishes_items(ddb, composite_table):
    ddb.put_item(TableName=composite_table, Item={"pk": {"S": "p1"}, "sk": {"N": "1"}, "v": {"S": "a"}})
    ddb.put_item(TableName=composite_table, Item={"pk": {"S": "p1"}, "sk": {"N": "2"}, "v": {"S": "b"}})
    out1 = ddb.get_item(TableName=composite_table, Key={"pk": {"S": "p1"}, "sk": {"N": "1"}})
    out2 = ddb.get_item(TableName=composite_table, Key={"pk": {"S": "p1"}, "sk": {"N": "2"}})
    assert out1["Item"]["v"] == {"S": "a"}
    assert out2["Item"]["v"] == {"S": "b"}


# ---------------------------------------------------------------------------
# AttributeValue type coverage

def test_attribute_value_full_type_coverage(ddb, hash_table):
    item = {
        "id": {"S": "types"},
        "s": {"S": "hello"},
        "n": {"N": "123.456789012345678901234567890123456789"},  # 38-digit precision
        "b": {"B": b"binary-bytes"},
        "bool_true": {"BOOL": True},
        "bool_false": {"BOOL": False},
        "null_val": {"NULL": True},
        "list": {"L": [{"S": "a"}, {"N": "1"}]},
        "map": {"M": {"inner": {"S": "x"}}},
        "ss": {"SS": ["a", "b", "c"]},
        "ns": {"NS": ["1", "2", "3"]},
    }
    ddb.put_item(TableName=hash_table, Item=item)
    got = ddb.get_item(TableName=hash_table, Key={"id": {"S": "types"}})["Item"]
    # Check each type round-trips. (Sets may be in any order — compare as sets.)
    assert got["s"] == {"S": "hello"}
    assert got["n"]["N"] == "123.456789012345678901234567890123456789"
    assert got["b"]["B"] == b"binary-bytes"
    assert got["bool_true"]["BOOL"] is True
    assert got["bool_false"]["BOOL"] is False
    assert got["null_val"]["NULL"] is True
    assert got["list"]["L"] == [{"S": "a"}, {"N": "1"}]
    assert got["map"]["M"] == {"inner": {"S": "x"}}
    assert set(got["ss"]["SS"]) == {"a", "b", "c"}
    assert set(got["ns"]["NS"]) == {"1", "2", "3"}


# ---------------------------------------------------------------------------
# DeleteItem

def test_delete_item_removes_it(ddb, hash_table):
    ddb.put_item(TableName=hash_table, Item={"id": {"S": "k1"}, "v": {"S": "x"}})
    ddb.delete_item(TableName=hash_table, Key={"id": {"S": "k1"}})
    out = ddb.get_item(TableName=hash_table, Key={"id": {"S": "k1"}})
    assert "Item" not in out


def test_delete_item_return_all_old(ddb, hash_table):
    ddb.put_item(TableName=hash_table, Item={"id": {"S": "k1"}, "v": {"S": "x"}})
    out = ddb.delete_item(
        TableName=hash_table,
        Key={"id": {"S": "k1"}},
        ReturnValues="ALL_OLD",
    )
    assert out["Attributes"] == {"id": {"S": "k1"}, "v": {"S": "x"}}


def test_delete_missing_item_is_idempotent(ddb, hash_table):
    """AWS-correct: DeleteItem on a missing key is a no-op success."""
    ddb.delete_item(TableName=hash_table, Key={"id": {"S": "never-existed"}})


# ---------------------------------------------------------------------------
# Table-not-found

def test_put_into_missing_table(ddb):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.put_item(TableName="no-such-table-items", Item={"id": {"S": "x"}})
    assert ei.value.response["Error"]["Code"] == "ResourceNotFoundException"


def test_get_from_missing_table(ddb):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.get_item(TableName="no-such-table-items", Key={"id": {"S": "x"}})
    assert ei.value.response["Error"]["Code"] == "ResourceNotFoundException"
