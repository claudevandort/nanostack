"""DynamoDB PartiQL conformance — v0.2.4.

Phase 1 covers ExecuteStatement on SELECT (Query + Scan + projection +
parameterized + pagination). Later phases extend with INSERT/UPDATE/DELETE
and ExecuteTransaction/BatchExecuteStatement.
"""

from __future__ import annotations

import uuid

import boto3
import botocore.exceptions
import pytest
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


def _unique_table(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


@pytest.fixture
def simple_table(ddb):
    name = _unique_table("ptq")
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
def composite_table(ddb):
    name = _unique_table("ptqc")
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
    yield name
    try:
        ddb.delete_table(TableName=name)
    except botocore.exceptions.ClientError:
        pass


# ---------------------------------------------------------------------------
# SELECT * (scan + query)


def test_select_all_scan(ddb, simple_table):
    for i in range(3):
        ddb.put_item(TableName=simple_table, Item={"id": {"S": f"k{i}"}})
    out = ddb.execute_statement(Statement=f'SELECT * FROM "{simple_table}"')
    assert sorted(it["id"]["S"] for it in out["Items"]) == ["k0", "k1", "k2"]


def test_select_pk_eq_with_parameter(ddb, simple_table):
    ddb.put_item(TableName=simple_table, Item={"id": {"S": "a"}, "v": {"N": "1"}})
    ddb.put_item(TableName=simple_table, Item={"id": {"S": "b"}, "v": {"N": "2"}})
    out = ddb.execute_statement(
        Statement=f'SELECT * FROM "{simple_table}" WHERE id = ?',
        Parameters=[{"S": "a"}],
    )
    assert len(out["Items"]) == 1
    assert out["Items"][0]["id"]["S"] == "a"
    assert out["Items"][0]["v"]["N"] == "1"


def test_select_pk_eq_with_string_literal(ddb, simple_table):
    ddb.put_item(TableName=simple_table, Item={"id": {"S": "lit"}, "v": {"S": "hello"}})
    out = ddb.execute_statement(Statement=f"SELECT * FROM \"{simple_table}\" WHERE id = 'lit'")
    assert len(out["Items"]) == 1
    assert out["Items"][0]["v"]["S"] == "hello"


def test_select_unmatched_pk_returns_empty(ddb, simple_table):
    ddb.put_item(TableName=simple_table, Item={"id": {"S": "x"}})
    out = ddb.execute_statement(
        Statement=f'SELECT * FROM "{simple_table}" WHERE id = ?',
        Parameters=[{"S": "missing"}],
    )
    assert out["Items"] == []


# ---------------------------------------------------------------------------
# SELECT projection list


def test_select_projection(ddb, simple_table):
    ddb.put_item(TableName=simple_table, Item={
        "id": {"S": "k1"},
        "name": {"S": "Alice"},
        "age": {"N": "30"},
    })
    out = ddb.execute_statement(
        Statement=f'SELECT name FROM "{simple_table}" WHERE id = ?',
        Parameters=[{"S": "k1"}],
    )
    assert len(out["Items"]) == 1
    item = out["Items"][0]
    assert "name" in item
    assert item["name"]["S"] == "Alice"
    # Projection drops unrequested attrs.
    assert "id" not in item
    assert "age" not in item


def test_select_multi_column_projection(ddb, simple_table):
    ddb.put_item(TableName=simple_table, Item={
        "id": {"S": "k1"},
        "name": {"S": "Alice"},
        "age": {"N": "30"},
    })
    out = ddb.execute_statement(
        Statement=f'SELECT id, age FROM "{simple_table}" WHERE id = ?',
        Parameters=[{"S": "k1"}],
    )
    item = out["Items"][0]
    assert set(item.keys()) == {"id", "age"}


# ---------------------------------------------------------------------------
# Composite-key SK predicates


def test_select_pk_eq_sk_eq(ddb, composite_table):
    ddb.put_item(TableName=composite_table, Item={"pk": {"S": "p1"}, "sk": {"S": "a"}})
    ddb.put_item(TableName=composite_table, Item={"pk": {"S": "p1"}, "sk": {"S": "b"}})
    ddb.put_item(TableName=composite_table, Item={"pk": {"S": "p2"}, "sk": {"S": "a"}})
    out = ddb.execute_statement(
        Statement=f'SELECT * FROM "{composite_table}" WHERE pk = ? AND sk = ?',
        Parameters=[{"S": "p1"}, {"S": "a"}],
    )
    assert len(out["Items"]) == 1
    assert out["Items"][0]["sk"]["S"] == "a"


def test_select_pk_eq_sk_begins_with(ddb, composite_table):
    for sk in ["alpha", "alpine", "beta"]:
        ddb.put_item(TableName=composite_table, Item={"pk": {"S": "p1"}, "sk": {"S": sk}})
    out = ddb.execute_statement(
        Statement=f'SELECT * FROM "{composite_table}" WHERE pk = ? AND begins_with(sk, ?)',
        Parameters=[{"S": "p1"}, {"S": "alp"}],
    )
    sks = sorted(it["sk"]["S"] for it in out["Items"])
    assert sks == ["alpha", "alpine"]


def test_select_pk_eq_sk_between(ddb, composite_table):
    for sk in ["a", "b", "c", "d"]:
        ddb.put_item(TableName=composite_table, Item={"pk": {"S": "p1"}, "sk": {"S": sk}})
    out = ddb.execute_statement(
        Statement=f'SELECT * FROM "{composite_table}" WHERE pk = ? AND sk BETWEEN ? AND ?',
        Parameters=[{"S": "p1"}, {"S": "b"}, {"S": "c"}],
    )
    sks = sorted(it["sk"]["S"] for it in out["Items"])
    assert sks == ["b", "c"]


# ---------------------------------------------------------------------------
# Error paths


def test_select_table_not_found_returns_not_found(ddb):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.execute_statement(Statement='SELECT * FROM "nope_xyz_partiql_test"')
    assert ei.value.response["Error"]["Code"] == "ResourceNotFoundException"


def test_syntax_error_returns_validation(ddb, simple_table):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.execute_statement(Statement="SELECT FROM nope")
    assert ei.value.response["Error"]["Code"] == "ValidationException"


def test_unsupported_statement_returns_validation(ddb, simple_table):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.execute_statement(Statement="DROP TABLE foo")
    assert ei.value.response["Error"]["Code"] == "ValidationException"


def test_parameter_count_mismatch_returns_validation(ddb, simple_table):
    # 2 ? in the statement but only 1 in Parameters.
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.execute_statement(
            Statement=f'SELECT * FROM "{simple_table}" WHERE id = ? AND v = ?',
            Parameters=[{"S": "a"}],
        )
    assert ei.value.response["Error"]["Code"] == "ValidationException"


def test_unsupported_transaction_phase_returns_validation(ddb):
    # ExecuteTransaction is stubbed until Phase 3.
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.execute_transaction(TransactStatements=[{"Statement": 'SELECT * FROM "x"'}])
    assert ei.value.response["Error"]["Code"] == "ValidationException"
