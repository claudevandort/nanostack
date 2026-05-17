"""DynamoDB PartiQL via `aws dynamodb` v2 CLI (v0.2.4)."""

from __future__ import annotations

import json
import secrets

import pytest

from conftest import run_aws


@pytest.fixture
def partiql_table():
    name = f"cli_ptq_{secrets.token_hex(4)}"
    run_aws(
        "dynamodb", "create-table",
        "--table-name", name,
        "--attribute-definitions", "AttributeName=id,AttributeType=S",
        "--key-schema", "AttributeName=id,KeyType=HASH",
        "--billing-mode", "PAY_PER_REQUEST",
    )
    yield name
    run_aws("dynamodb", "delete-table", "--table-name", name, check=False)


def test_execute_statement_select_scan(partiql_table):
    run_aws(
        "dynamodb", "execute-statement",
        "--statement", f"INSERT INTO \"{partiql_table}\" VALUE {{'id': 'k1'}}",
    )
    out = run_aws(
        "dynamodb", "execute-statement",
        "--statement", f"SELECT * FROM \"{partiql_table}\"",
        json_output=True,
    ).json()
    assert len(out["Items"]) >= 1


def test_execute_statement_insert_with_parameters(partiql_table):
    run_aws(
        "dynamodb", "execute-statement",
        "--statement", f"INSERT INTO \"{partiql_table}\" VALUE {{'id': ?, 'n': ?}}",
        "--parameters", json.dumps([{"S": "p1"}, {"N": "100"}]),
    )
    out = run_aws(
        "dynamodb", "execute-statement",
        "--statement", f"SELECT * FROM \"{partiql_table}\" WHERE id = ?",
        "--parameters", json.dumps([{"S": "p1"}]),
        json_output=True,
    ).json()
    assert out["Items"][0]["n"]["N"] == "100"


def test_execute_statement_update_set(partiql_table):
    run_aws(
        "dynamodb", "execute-statement",
        "--statement", f"INSERT INTO \"{partiql_table}\" VALUE {{'id': 'up'}}",
    )
    run_aws(
        "dynamodb", "execute-statement",
        "--statement", f"UPDATE \"{partiql_table}\" SET v = ? WHERE id = ?",
        "--parameters", json.dumps([{"S": "fresh"}, {"S": "up"}]),
    )
    out = run_aws(
        "dynamodb", "execute-statement",
        "--statement", f"SELECT * FROM \"{partiql_table}\" WHERE id = ?",
        "--parameters", json.dumps([{"S": "up"}]),
        json_output=True,
    ).json()
    assert out["Items"][0]["v"]["S"] == "fresh"


def test_execute_transaction(partiql_table):
    statements = [
        {"Statement": f"INSERT INTO \"{partiql_table}\" VALUE {{'id': 'tx1'}}"},
        {"Statement": f"INSERT INTO \"{partiql_table}\" VALUE {{'id': 'tx2'}}"},
    ]
    run_aws(
        "dynamodb", "execute-transaction",
        "--transact-statements", json.dumps(statements),
        json_output=True,
    )
    out = run_aws(
        "dynamodb", "execute-statement",
        "--statement", f"SELECT * FROM \"{partiql_table}\"",
        json_output=True,
    ).json()
    ids = {it["id"]["S"] for it in out["Items"]}
    assert "tx1" in ids and "tx2" in ids
