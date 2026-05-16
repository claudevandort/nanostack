"""DynamoDB table-management conformance (M15-tables, Phase 2).

CreateTable / DescribeTable / ListTables / UpdateTable / DeleteTable.
GSI/LSI definitions are accepted + surfaced on DescribeTable; Query
against them lands in Phase 8 (M15-gsi).
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


def _cleanup_table(ddb, name: str) -> None:
    try:
        ddb.delete_table(TableName=name)
    except botocore.exceptions.ClientError:
        pass


# ---------------------------------------------------------------------------
# CreateTable

def test_create_table_with_hash_key(ddb):
    name = "test-create-hash"
    try:
        out = ddb.create_table(
            TableName=name,
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        td = out["TableDescription"]
        assert td["TableName"] == name
        assert td["TableStatus"] == "ACTIVE"
        assert td["KeySchema"] == [{"AttributeName": "id", "KeyType": "HASH"}]
        assert td["BillingModeSummary"]["BillingMode"] == "PAY_PER_REQUEST"
    finally:
        _cleanup_table(ddb, name)


def test_create_table_with_hash_and_range_keys(ddb):
    name = "test-create-composite"
    try:
        out = ddb.create_table(
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
        td = out["TableDescription"]
        assert len(td["KeySchema"]) == 2
        assert td["AttributeDefinitions"] == [
            {"AttributeName": "pk", "AttributeType": "S"},
            {"AttributeName": "sk", "AttributeType": "N"},
        ]
    finally:
        _cleanup_table(ddb, name)


def test_create_table_with_gsi_definition(ddb):
    name = "test-create-gsi"
    try:
        out = ddb.create_table(
            TableName=name,
            KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}],
            AttributeDefinitions=[
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "gsi_pk", "AttributeType": "S"},
            ],
            GlobalSecondaryIndexes=[{
                "IndexName": "gsi1",
                "KeySchema": [{"AttributeName": "gsi_pk", "KeyType": "HASH"}],
                "Projection": {"ProjectionType": "ALL"},
            }],
            BillingMode="PAY_PER_REQUEST",
        )
        td = out["TableDescription"]
        assert len(td.get("GlobalSecondaryIndexes", [])) == 1
        assert td["GlobalSecondaryIndexes"][0]["IndexName"] == "gsi1"
    finally:
        _cleanup_table(ddb, name)


def test_create_table_duplicate_returns_resource_in_use(ddb):
    name = "test-dup"
    try:
        ddb.create_table(
            TableName=name,
            KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        with pytest.raises(botocore.exceptions.ClientError) as ei:
            ddb.create_table(
                TableName=name,
                KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}],
                AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
                BillingMode="PAY_PER_REQUEST",
            )
        assert ei.value.response["Error"]["Code"] == "ResourceInUseException"
    finally:
        _cleanup_table(ddb, name)


def test_create_table_rejects_undeclared_key_attribute(ddb):
    """KeySchema must only reference attributes in AttributeDefinitions."""
    name = "test-undeclared"
    try:
        with pytest.raises(botocore.exceptions.ClientError) as ei:
            ddb.create_table(
                TableName=name,
                KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}],
                AttributeDefinitions=[{"AttributeName": "other", "AttributeType": "S"}],
                BillingMode="PAY_PER_REQUEST",
            )
        assert ei.value.response["Error"]["Code"] == "ValidationException"
    finally:
        _cleanup_table(ddb, name)


def test_create_table_rejects_short_name(ddb):
    """Table names must be 3-255 chars."""
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.create_table(
            TableName="ab",
            KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
    assert ei.value.response["Error"]["Code"] == "ValidationException"


# ---------------------------------------------------------------------------
# DescribeTable

def test_describe_table_returns_full_shape(ddb):
    name = "test-describe"
    try:
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
        out = ddb.describe_table(TableName=name)
        t = out["Table"]
        assert t["TableName"] == name
        assert t["TableStatus"] == "ACTIVE"
        assert t["ItemCount"] == 0  # Phase 2: no items yet
        assert "CreationDateTime" in t
        assert len(t["KeySchema"]) == 2
    finally:
        _cleanup_table(ddb, name)


def test_describe_table_missing_returns_resource_not_found(ddb):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.describe_table(TableName="does-not-exist-table")
    assert ei.value.response["Error"]["Code"] == "ResourceNotFoundException"


# ---------------------------------------------------------------------------
# ListTables

def test_list_tables_returns_all_in_lex_order(ddb):
    names = ["alpha-list", "bravo-list", "charlie-list"]
    try:
        for n in names:
            ddb.create_table(
                TableName=n,
                KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}],
                AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
                BillingMode="PAY_PER_REQUEST",
            )
        out = ddb.list_tables()
        # Other tests may run before/after; just check our three names appear
        # in lex order relative to each other.
        all_names = out["TableNames"]
        ours = [n for n in all_names if n in names]
        assert ours == sorted(names), f"expected lex order, got {ours}"
    finally:
        for n in names:
            _cleanup_table(ddb, n)


def test_list_tables_pagination(ddb):
    names = sorted([f"page-{i}-{abs(hash('x')) % 1000}" for i in range(3)])
    try:
        for n in names:
            ddb.create_table(
                TableName=n,
                KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}],
                AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
                BillingMode="PAY_PER_REQUEST",
            )
        # Filter via list-side comparison (server returns all tables; this
        # test focuses on the pagination protocol).
        out = ddb.list_tables(Limit=2)
        first_page = out["TableNames"]
        assert len(first_page) <= 2
        if len(first_page) < len(out.get("TableNames", [])) or out.get("LastEvaluatedTableName"):
            cursor = out["LastEvaluatedTableName"]
            page2 = ddb.list_tables(Limit=2, ExclusiveStartTableName=cursor)
            # Names in page2 should all be strictly > cursor.
            for p in page2["TableNames"]:
                assert p > cursor
    finally:
        for n in names:
            _cleanup_table(ddb, n)


# ---------------------------------------------------------------------------
# DeleteTable

def test_delete_table_returns_description(ddb):
    name = "test-delete"
    ddb.create_table(
        TableName=name,
        KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    out = ddb.delete_table(TableName=name)
    assert out["TableDescription"]["TableName"] == name
    # Subsequent describe → ResourceNotFoundException
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.describe_table(TableName=name)
    assert ei.value.response["Error"]["Code"] == "ResourceNotFoundException"


def test_delete_table_missing_returns_resource_not_found(ddb):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.delete_table(TableName="no-such-table-x")
    assert ei.value.response["Error"]["Code"] == "ResourceNotFoundException"


# ---------------------------------------------------------------------------
# UpdateTable

def test_update_table_changes_billing_mode(ddb):
    name = "test-update-bm"
    try:
        ddb.create_table(
            TableName=name,
            KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        out = ddb.update_table(TableName=name, BillingMode="PROVISIONED")
        assert out["TableDescription"]["BillingModeSummary"]["BillingMode"] == "PROVISIONED"
        # Persists across DescribeTable.
        out = ddb.describe_table(TableName=name)
        assert out["Table"]["BillingModeSummary"]["BillingMode"] == "PROVISIONED"
    finally:
        _cleanup_table(ddb, name)


def test_update_table_missing_returns_resource_not_found(ddb):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.update_table(TableName="no-such-table-y", BillingMode="PROVISIONED")
    assert ei.value.response["Error"]["Code"] == "ResourceNotFoundException"
