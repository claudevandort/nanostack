"""DynamoDB transactional conformance (M15-tx, Phase 9).

TransactGetItems atomic snapshot, TransactWriteItems all-or-nothing
atomicity with per-op CancellationReasons.
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


def _unique(prefix, request):
    return f"{prefix}-{request.node.name.replace('[', '-').replace(']', '')[:80]}"


@pytest.fixture
def accounts_table(ddb, request):
    name = _unique("tx-acct", request)
    ddb.create_table(
        TableName=name,
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    ddb.put_item(TableName=name, Item={"id": {"S": "alice"}, "balance": {"N": "100"}})
    ddb.put_item(TableName=name, Item={"id": {"S": "bob"}, "balance": {"N": "50"}})
    yield name
    try:
        ddb.delete_table(TableName=name)
    except botocore.exceptions.ClientError:
        pass


# ---------------------------------------------------------------------------
# TransactGetItems

def test_transact_get_returns_items_in_order(ddb, accounts_table):
    out = ddb.transact_get_items(TransactItems=[
        {"Get": {"TableName": accounts_table, "Key": {"id": {"S": "alice"}}}},
        {"Get": {"TableName": accounts_table, "Key": {"id": {"S": "bob"}}}},
    ])
    balances = [r["Item"]["balance"]["N"] for r in out["Responses"]]
    assert balances == ["100", "50"]


def test_transact_get_missing_item_returns_empty_response(ddb, accounts_table):
    out = ddb.transact_get_items(TransactItems=[
        {"Get": {"TableName": accounts_table, "Key": {"id": {"S": "alice"}}}},
        {"Get": {"TableName": accounts_table, "Key": {"id": {"S": "ghost"}}}},
    ])
    assert "Item" in out["Responses"][0]
    assert "Item" not in out["Responses"][1]


# ---------------------------------------------------------------------------
# TransactWriteItems: success cases

def test_transact_write_transfer_atomic(ddb, accounts_table):
    """Classic transfer: subtract from one, add to another, atomically."""
    ddb.transact_write_items(TransactItems=[
        {"Update": {
            "TableName": accounts_table,
            "Key": {"id": {"S": "alice"}},
            "UpdateExpression": "SET balance = balance - :n",
            "ExpressionAttributeValues": {":n": {"N": "30"}},
        }},
        {"Update": {
            "TableName": accounts_table,
            "Key": {"id": {"S": "bob"}},
            "UpdateExpression": "SET balance = balance + :n",
            "ExpressionAttributeValues": {":n": {"N": "30"}},
        }},
    ])
    alice = ddb.get_item(TableName=accounts_table, Key={"id": {"S": "alice"}})["Item"]
    bob = ddb.get_item(TableName=accounts_table, Key={"id": {"S": "bob"}})["Item"]
    # Numbers come back as N (string); compare numerically.
    assert float(alice["balance"]["N"]) == 70
    assert float(bob["balance"]["N"]) == 80


def test_transact_write_put_and_delete(ddb, accounts_table):
    ddb.transact_write_items(TransactItems=[
        {"Put": {"TableName": accounts_table, "Item": {"id": {"S": "new"}, "balance": {"N": "1"}}}},
        {"Delete": {"TableName": accounts_table, "Key": {"id": {"S": "alice"}}}},
    ])
    assert "Item" in ddb.get_item(TableName=accounts_table, Key={"id": {"S": "new"}})
    assert "Item" not in ddb.get_item(TableName=accounts_table, Key={"id": {"S": "alice"}})


# ---------------------------------------------------------------------------
# TransactWriteItems: cancellation rollback

def test_transact_write_failing_condition_rolls_back_all(ddb, accounts_table):
    """If any op's condition fails, NO writes should land."""
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.transact_write_items(TransactItems=[
            {"Put": {
                "TableName": accounts_table,
                "Item": {"id": {"S": "charlie"}, "balance": {"N": "0"}},
                "ConditionExpression": "attribute_not_exists(id)",
            }},
            {"Put": {
                "TableName": accounts_table,
                "Item": {"id": {"S": "alice"}, "balance": {"N": "999"}},
                "ConditionExpression": "attribute_not_exists(id)",  # alice exists → fail
            }},
        ])
    assert ei.value.response["Error"]["Code"] == "TransactionCanceledException"
    # Neither write should have landed.
    assert "Item" not in ddb.get_item(TableName=accounts_table, Key={"id": {"S": "charlie"}})
    assert ddb.get_item(TableName=accounts_table, Key={"id": {"S": "alice"}})["Item"]["balance"]["N"] == "100"


def test_transact_write_cancellation_reasons_array(ddb, accounts_table):
    """The cancellation error includes a CancellationReasons array
    parallel to the input ops, marking which ops failed and why."""
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.transact_write_items(TransactItems=[
            {"Put": {
                "TableName": accounts_table,
                "Item": {"id": {"S": "ok"}, "balance": {"N": "1"}},
                "ConditionExpression": "attribute_not_exists(id)",
            }},
            {"Put": {
                "TableName": accounts_table,
                "Item": {"id": {"S": "alice"}, "balance": {"N": "999"}},
                "ConditionExpression": "attribute_not_exists(id)",  # FAIL
            }},
        ])
    reasons = ei.value.response.get("CancellationReasons", [])
    assert len(reasons) == 2
    # Op 0 passed; op 1 failed.
    assert reasons[0]["Code"] == "None"
    assert reasons[1]["Code"] == "ConditionalCheckFailed"


def test_transact_write_condition_check_only(ddb, accounts_table):
    """ConditionCheck is a no-op write that just gates the transaction."""
    # alice exists, so attribute_exists(id) passes; tx commits the put.
    ddb.transact_write_items(TransactItems=[
        {"ConditionCheck": {
            "TableName": accounts_table,
            "Key": {"id": {"S": "alice"}},
            "ConditionExpression": "attribute_exists(id)",
        }},
        {"Put": {
            "TableName": accounts_table,
            "Item": {"id": {"S": "verified"}, "ok": {"S": "true"}},
        }},
    ])
    assert "Item" in ddb.get_item(TableName=accounts_table, Key={"id": {"S": "verified"}})


def test_transact_write_too_many_ops_rejected(ddb, accounts_table):
    """Up to 100 ops per transaction."""
    ops = [
        {"Put": {"TableName": accounts_table, "Item": {"id": {"S": f"k{i}"}}}}
        for i in range(101)
    ]
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.transact_write_items(TransactItems=ops)
    assert ei.value.response["Error"]["Code"] == "ValidationException"


def test_transact_write_cross_table_atomic(ddb, request):
    """Atomicity holds across multiple tables."""
    a = _unique("tx-A", request)
    b = _unique("tx-B", request)
    for name in (a, b):
        ddb.create_table(
            TableName=name,
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
    try:
        ddb.put_item(TableName=a, Item={"id": {"S": "k"}, "v": {"S": "old"}})
        ddb.transact_write_items(TransactItems=[
            {"Update": {
                "TableName": a, "Key": {"id": {"S": "k"}},
                "UpdateExpression": "SET v = :n",
                "ExpressionAttributeValues": {":n": {"S": "new"}},
            }},
            {"Put": {
                "TableName": b, "Item": {"id": {"S": "k"}, "src": {"S": "A"}},
            }},
        ])
        assert ddb.get_item(TableName=a, Key={"id": {"S": "k"}})["Item"]["v"] == {"S": "new"}
        assert ddb.get_item(TableName=b, Key={"id": {"S": "k"}})["Item"]["src"] == {"S": "A"}
    finally:
        for name in (a, b):
            try:
                ddb.delete_table(TableName=name)
            except botocore.exceptions.ClientError:
                pass


# ---------------------------------------------------------------------------
# Backfill (v0.2.1): mixed-op transactions.

def test_transact_write_mixed_ops(ddb, accounts_table):
    """One TransactWriteItems carrying Put + Update + Delete + ConditionCheck.
    All four must succeed atomically."""
    # Seed an extra row we'll be removing.
    ddb.put_item(TableName=accounts_table, Item={"id": {"S": "charlie"}, "balance": {"N": "200"}})

    ddb.transact_write_items(TransactItems=[
        # ConditionCheck: alice must exist (she does).
        {"ConditionCheck": {
            "TableName": accounts_table,
            "Key": {"id": {"S": "alice"}},
            "ConditionExpression": "attribute_exists(id)",
        }},
        # Update bob's balance.
        {"Update": {
            "TableName": accounts_table,
            "Key": {"id": {"S": "bob"}},
            "UpdateExpression": "SET balance = balance + :n",
            "ExpressionAttributeValues": {":n": {"N": "10"}},
        }},
        # Put a fresh row.
        {"Put": {
            "TableName": accounts_table,
            "Item": {"id": {"S": "dana"}, "balance": {"N": "1"}},
        }},
        # Delete charlie.
        {"Delete": {
            "TableName": accounts_table,
            "Key": {"id": {"S": "charlie"}},
        }},
    ])

    # Verify all four landed.
    bob = ddb.get_item(TableName=accounts_table, Key={"id": {"S": "bob"}})["Item"]
    assert float(bob["balance"]["N"]) == 60  # 50 + 10
    assert "Item" in ddb.get_item(TableName=accounts_table, Key={"id": {"S": "dana"}})
    assert "Item" not in ddb.get_item(TableName=accounts_table, Key={"id": {"S": "charlie"}})
