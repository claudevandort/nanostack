"""DynamoDB Backups + PITR via `aws dynamodb` v2 CLI (v0.2.5)."""

from __future__ import annotations

import json
import secrets

import pytest

from conftest import run_aws


@pytest.fixture
def backup_table():
    name = f"cli_bkp_{secrets.token_hex(4)}"
    run_aws(
        "dynamodb", "create-table",
        "--table-name", name,
        "--attribute-definitions", "AttributeName=id,AttributeType=S",
        "--key-schema", "AttributeName=id,KeyType=HASH",
        "--billing-mode", "PAY_PER_REQUEST",
    )
    run_aws(
        "dynamodb", "put-item",
        "--table-name", name,
        "--item", json.dumps({"id": {"S": "u1"}, "v": {"N": "100"}}),
    )
    yield name
    run_aws("dynamodb", "delete-table", "--table-name", name, check=False)


def test_create_and_describe_backup(backup_table):
    created = run_aws(
        "dynamodb", "create-backup",
        "--table-name", backup_table,
        "--backup-name", "daily",
        json_output=True,
    ).json()
    arn = created["BackupDetails"]["BackupArn"]
    assert created["BackupDetails"]["BackupStatus"] == "AVAILABLE"

    desc = run_aws(
        "dynamodb", "describe-backup",
        "--backup-arn", arn,
        json_output=True,
    ).json()
    assert desc["BackupDescription"]["BackupDetails"]["BackupArn"] == arn


def test_list_and_delete_backup(backup_table):
    arn = run_aws(
        "dynamodb", "create-backup",
        "--table-name", backup_table,
        "--backup-name", "for-delete",
        json_output=True,
    ).json()["BackupDetails"]["BackupArn"]

    listed = run_aws(
        "dynamodb", "list-backups",
        "--table-name", backup_table,
        json_output=True,
    ).json()
    assert any(b["BackupArn"] == arn for b in listed["BackupSummaries"])

    deleted = run_aws(
        "dynamodb", "delete-backup",
        "--backup-arn", arn,
        json_output=True,
    ).json()
    assert deleted["BackupDescription"]["BackupDetails"]["BackupStatus"] == "DELETED"


def test_restore_from_backup(backup_table):
    arn = run_aws(
        "dynamodb", "create-backup",
        "--table-name", backup_table,
        "--backup-name", "snap",
        json_output=True,
    ).json()["BackupDetails"]["BackupArn"]

    target = f"cli_restored_{secrets.token_hex(4)}"
    out = run_aws(
        "dynamodb", "restore-table-from-backup",
        "--target-table-name", target,
        "--backup-arn", arn,
        json_output=True,
    ).json()
    try:
        assert out["TableDescription"]["TableName"] == target
        got = run_aws(
            "dynamodb", "get-item",
            "--table-name", target,
            "--key", json.dumps({"id": {"S": "u1"}}),
            json_output=True,
        ).json()
        assert got["Item"]["v"]["N"] == "100"
    finally:
        run_aws("dynamodb", "delete-table", "--table-name", target, check=False)


def test_update_and_describe_continuous_backups(backup_table):
    out = run_aws(
        "dynamodb", "update-continuous-backups",
        "--table-name", backup_table,
        "--point-in-time-recovery-specification", "PointInTimeRecoveryEnabled=true",
        json_output=True,
    ).json()
    pitr = out["ContinuousBackupsDescription"]["PointInTimeRecoveryDescription"]
    assert pitr["PointInTimeRecoveryStatus"] == "ENABLED"

    desc = run_aws(
        "dynamodb", "describe-continuous-backups",
        "--table-name", backup_table,
        json_output=True,
    ).json()
    assert desc["ContinuousBackupsDescription"]["ContinuousBackupsStatus"] == "ENABLED"
