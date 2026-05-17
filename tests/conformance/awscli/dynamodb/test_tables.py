"""DynamoDB table management via `aws dynamodb` v2 CLI (v0.2.1)."""

from __future__ import annotations

import secrets

import pytest

from conftest import run_aws


def _unique(prefix: str) -> str:
    return f"{prefix}-{secrets.token_hex(4)}"


def _delete_table(name: str) -> None:
    run_aws("dynamodb", "delete-table", "--table-name", name, check=False)


def test_create_describe_delete_table():
    name = _unique("cli-ddb-tbl")
    try:
        create = run_aws(
            "dynamodb", "create-table",
            "--table-name", name,
            "--attribute-definitions", "AttributeName=id,AttributeType=S",
            "--key-schema", "AttributeName=id,KeyType=HASH",
            "--billing-mode", "PAY_PER_REQUEST",
            json_output=True,
        )
        td = create.json()["TableDescription"]
        assert td["TableName"] == name
        assert td["TableStatus"] == "ACTIVE"

        describe = run_aws(
            "dynamodb", "describe-table", "--table-name", name,
            json_output=True,
        )
        t = describe.json()["Table"]
        assert t["KeySchema"] == [{"AttributeName": "id", "KeyType": "HASH"}]
    finally:
        _delete_table(name)


def test_list_tables_returns_array():
    out = run_aws("dynamodb", "list-tables", json_output=True)
    body = out.json()
    assert isinstance(body.get("TableNames"), list)


def test_create_table_with_gsi():
    name = _unique("cli-ddb-gsi")
    try:
        run_aws(
            "dynamodb", "create-table",
            "--table-name", name,
            "--attribute-definitions",
            "AttributeName=id,AttributeType=S",
            "AttributeName=tag,AttributeType=S",
            "--key-schema", "AttributeName=id,KeyType=HASH",
            "--global-secondary-indexes",
            (
                "IndexName=by-tag,"
                "KeySchema=[{AttributeName=tag,KeyType=HASH}],"
                "Projection={ProjectionType=ALL}"
            ),
            "--billing-mode", "PAY_PER_REQUEST",
            json_output=True,
        )
        describe = run_aws(
            "dynamodb", "describe-table", "--table-name", name,
            json_output=True,
        )
        gsi = describe.json()["Table"].get("GlobalSecondaryIndexes", [])
        assert len(gsi) == 1
        assert gsi[0]["IndexName"] == "by-tag"
    finally:
        _delete_table(name)
