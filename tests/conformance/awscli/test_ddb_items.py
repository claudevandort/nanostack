"""DynamoDB item CRUD via `aws dynamodb` v2 CLI (v0.2.1)."""

from __future__ import annotations

import json
import secrets

import pytest

from conftest import run_aws


@pytest.fixture
def ddb_table():
    name = f"cli-items-{secrets.token_hex(4)}"
    run_aws(
        "dynamodb", "create-table",
        "--table-name", name,
        "--attribute-definitions", "AttributeName=id,AttributeType=S",
        "--key-schema", "AttributeName=id,KeyType=HASH",
        "--billing-mode", "PAY_PER_REQUEST",
    )
    yield name
    run_aws("dynamodb", "delete-table", "--table-name", name, check=False)


def test_put_get_roundtrip(ddb_table):
    run_aws(
        "dynamodb", "put-item",
        "--table-name", ddb_table,
        "--item", json.dumps({"id": {"S": "k1"}, "title": {"S": "Inception"}, "year": {"N": "2010"}}),
    )
    out = run_aws(
        "dynamodb", "get-item",
        "--table-name", ddb_table,
        "--key", json.dumps({"id": {"S": "k1"}}),
        json_output=True,
    )
    item = out.json()["Item"]
    assert item["title"] == {"S": "Inception"}
    assert item["year"] == {"N": "2010"}


def test_update_item_with_expression_flags(ddb_table):
    """`--update-expression` + `--expression-attribute-values` flags work."""
    run_aws(
        "dynamodb", "put-item",
        "--table-name", ddb_table,
        "--item", json.dumps({"id": {"S": "k"}, "tally": {"N": "5"}}),
    )
    run_aws(
        "dynamodb", "update-item",
        "--table-name", ddb_table,
        "--key", json.dumps({"id": {"S": "k"}}),
        "--update-expression", "SET tally = tally + :inc",
        "--expression-attribute-values", json.dumps({":inc": {"N": "3"}}),
    )
    out = run_aws(
        "dynamodb", "get-item",
        "--table-name", ddb_table,
        "--key", json.dumps({"id": {"S": "k"}}),
        json_output=True,
    )
    assert out.json()["Item"]["tally"]["N"] in {"8", "8.0"}


def test_delete_item_removes_it(ddb_table):
    run_aws(
        "dynamodb", "put-item",
        "--table-name", ddb_table,
        "--item", json.dumps({"id": {"S": "k-del"}, "v": {"S": "x"}}),
    )
    run_aws(
        "dynamodb", "delete-item",
        "--table-name", ddb_table,
        "--key", json.dumps({"id": {"S": "k-del"}}),
    )
    out = run_aws(
        "dynamodb", "get-item",
        "--table-name", ddb_table,
        "--key", json.dumps({"id": {"S": "k-del"}}),
        json_output=True,
    )
    # AWS CLI v2 returns an empty body (or `{}`) when no item.
    body = out.stdout.strip()
    assert body == "" or "Item" not in json.loads(body)
