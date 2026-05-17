"""DynamoDB TTL via `aws dynamodb` v2 CLI (v0.2.3)."""

from __future__ import annotations

import secrets

import pytest

from conftest import run_aws


@pytest.fixture
def ttl_table():
    name = f"cli-ttl-{secrets.token_hex(4)}"
    run_aws(
        "dynamodb", "create-table",
        "--table-name", name,
        "--attribute-definitions", "AttributeName=id,AttributeType=S",
        "--key-schema", "AttributeName=id,KeyType=HASH",
        "--billing-mode", "PAY_PER_REQUEST",
    )
    yield name
    run_aws("dynamodb", "delete-table", "--table-name", name, check=False)


def test_describe_ttl_never_configured(ttl_table):
    out = run_aws(
        "dynamodb", "describe-time-to-live",
        "--table-name", ttl_table,
        json_output=True,
    ).json()
    assert out["TimeToLiveDescription"]["TimeToLiveStatus"] == "DISABLED"


def test_enable_ttl_then_describe(ttl_table):
    out = run_aws(
        "dynamodb", "update-time-to-live",
        "--table-name", ttl_table,
        "--time-to-live-specification", "Enabled=true,AttributeName=expires_at",
        json_output=True,
    ).json()
    spec = out["TimeToLiveSpecification"]
    assert spec["Enabled"] is True
    assert spec["AttributeName"] == "expires_at"

    desc = run_aws(
        "dynamodb", "describe-time-to-live",
        "--table-name", ttl_table,
        json_output=True,
    ).json()
    assert desc["TimeToLiveDescription"]["TimeToLiveStatus"] == "ENABLED"
    assert desc["TimeToLiveDescription"]["AttributeName"] == "expires_at"


def test_disable_ttl_after_enable(ttl_table):
    run_aws(
        "dynamodb", "update-time-to-live",
        "--table-name", ttl_table,
        "--time-to-live-specification", "Enabled=true,AttributeName=ttl",
    )
    out = run_aws(
        "dynamodb", "update-time-to-live",
        "--table-name", ttl_table,
        "--time-to-live-specification", "Enabled=false,AttributeName=ttl",
        json_output=True,
    ).json()
    assert out["TimeToLiveSpecification"]["Enabled"] is False

    desc = run_aws(
        "dynamodb", "describe-time-to-live",
        "--table-name", ttl_table,
        json_output=True,
    ).json()
    assert desc["TimeToLiveDescription"]["TimeToLiveStatus"] == "DISABLED"
