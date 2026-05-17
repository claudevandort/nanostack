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


# ---------------------------------------------------------------------------
# Phase 2: INSERT / UPDATE / DELETE


def test_insert_simple(ddb, simple_table):
    ddb.execute_statement(
        Statement=f"INSERT INTO \"{simple_table}\" VALUE {{'id': ?, 'name': ?}}",
        Parameters=[{"S": "k1"}, {"S": "Alice"}],
    )
    item = ddb.get_item(TableName=simple_table, Key={"id": {"S": "k1"}})["Item"]
    assert item["id"]["S"] == "k1"
    assert item["name"]["S"] == "Alice"


def test_insert_with_inline_string_literal(ddb, simple_table):
    ddb.execute_statement(
        Statement=f"INSERT INTO \"{simple_table}\" VALUE {{'id': 'k_inline', 'name': 'Charlie'}}",
    )
    item = ddb.get_item(TableName=simple_table, Key={"id": {"S": "k_inline"}})["Item"]
    assert item["name"]["S"] == "Charlie"


def test_insert_with_number_literal(ddb, simple_table):
    ddb.execute_statement(
        Statement=f"INSERT INTO \"{simple_table}\" VALUE {{'id': ?, 'count': 42}}",
        Parameters=[{"S": "kn"}],
    )
    item = ddb.get_item(TableName=simple_table, Key={"id": {"S": "kn"}})["Item"]
    assert item["count"]["N"] == "42"


def test_insert_with_boolean_and_null(ddb, simple_table):
    ddb.execute_statement(
        Statement=f"INSERT INTO \"{simple_table}\" VALUE {{'id': ?, 'active': true, 'missing': null}}",
        Parameters=[{"S": "kb"}],
    )
    item = ddb.get_item(TableName=simple_table, Key={"id": {"S": "kb"}})["Item"]
    assert item["active"]["BOOL"] is True
    assert item["missing"]["NULL"] is True


def test_update_set_simple_replace(ddb, simple_table):
    ddb.put_item(TableName=simple_table, Item={"id": {"S": "k1"}, "v": {"S": "old"}})
    ddb.execute_statement(
        Statement=f"UPDATE \"{simple_table}\" SET v = ? WHERE id = ?",
        Parameters=[{"S": "new"}, {"S": "k1"}],
    )
    item = ddb.get_item(TableName=simple_table, Key={"id": {"S": "k1"}})["Item"]
    assert item["v"]["S"] == "new"


def test_update_set_atomic_counter(ddb, simple_table):
    ddb.put_item(TableName=simple_table, Item={"id": {"S": "ctr"}, "count": {"N": "10"}})
    ddb.execute_statement(
        Statement=f"UPDATE \"{simple_table}\" SET count = count + ? WHERE id = ?",
        Parameters=[{"N": "5"}, {"S": "ctr"}],
    )
    item = ddb.get_item(TableName=simple_table, Key={"id": {"S": "ctr"}})["Item"]
    assert item["count"]["N"] in {"15", "15.0"}


def test_update_set_creates_new_attribute(ddb, simple_table):
    ddb.put_item(TableName=simple_table, Item={"id": {"S": "k1"}})
    ddb.execute_statement(
        Statement=f"UPDATE \"{simple_table}\" SET added = ? WHERE id = ?",
        Parameters=[{"S": "yes"}, {"S": "k1"}],
    )
    item = ddb.get_item(TableName=simple_table, Key={"id": {"S": "k1"}})["Item"]
    assert item["added"]["S"] == "yes"


def test_update_multi_assignment(ddb, simple_table):
    ddb.put_item(TableName=simple_table, Item={"id": {"S": "k1"}})
    ddb.execute_statement(
        Statement=f"UPDATE \"{simple_table}\" SET a = ?, b = ?, c = ? WHERE id = ?",
        Parameters=[{"S": "av"}, {"N": "2"}, {"BOOL": True}, {"S": "k1"}],
    )
    item = ddb.get_item(TableName=simple_table, Key={"id": {"S": "k1"}})["Item"]
    assert item["a"]["S"] == "av"
    assert item["b"]["N"] == "2"
    assert item["c"]["BOOL"] is True


def test_update_returning_all_old(ddb, simple_table):
    ddb.put_item(TableName=simple_table, Item={"id": {"S": "k1"}, "v": {"S": "old"}})
    out = ddb.execute_statement(
        Statement=f"UPDATE \"{simple_table}\" SET v = ? WHERE id = ? RETURNING ALL OLD *",
        Parameters=[{"S": "new"}, {"S": "k1"}],
    )
    assert out["Items"][0]["v"]["S"] == "old"


def test_update_returning_all_new(ddb, simple_table):
    ddb.put_item(TableName=simple_table, Item={"id": {"S": "k1"}, "v": {"S": "old"}})
    out = ddb.execute_statement(
        Statement=f"UPDATE \"{simple_table}\" SET v = ? WHERE id = ? RETURNING ALL NEW *",
        Parameters=[{"S": "new"}, {"S": "k1"}],
    )
    assert out["Items"][0]["v"]["S"] == "new"


def test_delete_simple(ddb, simple_table):
    ddb.put_item(TableName=simple_table, Item={"id": {"S": "k1"}})
    ddb.execute_statement(
        Statement=f"DELETE FROM \"{simple_table}\" WHERE id = ?",
        Parameters=[{"S": "k1"}],
    )
    assert "Item" not in ddb.get_item(TableName=simple_table, Key={"id": {"S": "k1"}})


def test_delete_returning_all_old(ddb, simple_table):
    ddb.put_item(TableName=simple_table, Item={"id": {"S": "k1"}, "v": {"S": "to-go"}})
    out = ddb.execute_statement(
        Statement=f"DELETE FROM \"{simple_table}\" WHERE id = ? RETURNING ALL OLD *",
        Parameters=[{"S": "k1"}],
    )
    assert out["Items"][0]["v"]["S"] == "to-go"


def test_delete_composite_key(ddb, composite_table):
    ddb.put_item(TableName=composite_table, Item={"pk": {"S": "p1"}, "sk": {"S": "a"}})
    ddb.put_item(TableName=composite_table, Item={"pk": {"S": "p1"}, "sk": {"S": "b"}})
    ddb.execute_statement(
        Statement=f"DELETE FROM \"{composite_table}\" WHERE pk = ? AND sk = ?",
        Parameters=[{"S": "p1"}, {"S": "a"}],
    )
    remaining = ddb.scan(TableName=composite_table)["Items"]
    sks = sorted(it["sk"]["S"] for it in remaining)
    assert sks == ["b"]


def test_update_without_where_returns_validation(ddb, simple_table):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.execute_statement(Statement=f"UPDATE \"{simple_table}\" SET v = ?", Parameters=[{"S": "x"}])
    assert ei.value.response["Error"]["Code"] == "ValidationException"


def test_unsupported_transaction_phase_returns_validation(ddb):
    # ExecuteTransaction is stubbed until Phase 3.
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.execute_transaction(TransactStatements=[{"Statement": 'SELECT * FROM "x"'}])
    assert ei.value.response["Error"]["Code"] == "ValidationException"
