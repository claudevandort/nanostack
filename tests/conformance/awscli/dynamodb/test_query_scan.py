"""DynamoDB Query + Scan via `aws dynamodb` v2 CLI (v0.2.1)."""

from __future__ import annotations

import json
import secrets

import pytest

from conftest import run_aws


@pytest.fixture
def composite_table():
    name = f"cli-qs-{secrets.token_hex(4)}"
    run_aws(
        "dynamodb", "create-table",
        "--table-name", name,
        "--attribute-definitions",
        "AttributeName=pk,AttributeType=S",
        "AttributeName=sk,AttributeType=N",
        "--key-schema",
        "AttributeName=pk,KeyType=HASH",
        "AttributeName=sk,KeyType=RANGE",
        "--billing-mode", "PAY_PER_REQUEST",
    )
    for i in [1, 2, 3]:
        run_aws(
            "dynamodb", "put-item",
            "--table-name", name,
            "--item", json.dumps({"pk": {"S": "p"}, "sk": {"N": str(i)}, "tag": {"S": "view"}}),
        )
    yield name
    run_aws("dynamodb", "delete-table", "--table-name", name, check=False)


def test_query_pk_only(composite_table):
    out = run_aws(
        "dynamodb", "query",
        "--table-name", composite_table,
        "--key-condition-expression", "pk = :p",
        "--expression-attribute-values", json.dumps({":p": {"S": "p"}}),
        json_output=True,
    )
    body = out.json()
    assert body["Count"] == 3


def test_query_with_sk_predicate(composite_table):
    out = run_aws(
        "dynamodb", "query",
        "--table-name", composite_table,
        "--key-condition-expression", "pk = :p AND sk > :t",
        "--expression-attribute-values", json.dumps({":p": {"S": "p"}, ":t": {"N": "1"}}),
        json_output=True,
    )
    body = out.json()
    assert body["Count"] == 2


def test_scan_with_filter(composite_table):
    out = run_aws(
        "dynamodb", "scan",
        "--table-name", composite_table,
        "--filter-expression", "tag = :t",
        "--expression-attribute-values", json.dumps({":t": {"S": "view"}}),
        json_output=True,
    )
    body = out.json()
    assert body["Count"] == 3
    assert body["ScannedCount"] == 3
