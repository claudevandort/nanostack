"""DynamoDB Backups + PITR conformance — v0.2.5.

Phase 1: CreateBackup, ListBackups, DescribeBackup, DeleteBackup —
the metadata + on-disk snapshot path. Phase 2 adds restore + PITR.
"""

from __future__ import annotations

import os
import socket
import subprocess
import tempfile
import time
import uuid

import boto3
import botocore.exceptions
import pytest
from botocore.config import Config

from conftest import endpoint


def _make_ddb(ep: str | None = None):
    return boto3.client(
        "dynamodb",
        endpoint_url=ep or endpoint(),
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
def seeded_table(ddb):
    """A 3-item table to back up + restore."""
    name = _unique_table("bkp")
    ddb.create_table(
        TableName=name,
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    for i in range(3):
        ddb.put_item(TableName=name, Item={"id": {"S": f"k{i}"}, "n": {"N": str(i)}})
    yield name
    try:
        ddb.delete_table(TableName=name)
    except botocore.exceptions.ClientError:
        pass


# ---------------------------------------------------------------------------
# CreateBackup


def test_create_backup_returns_details(ddb, seeded_table):
    out = ddb.create_backup(TableName=seeded_table, BackupName="daily")["BackupDetails"]
    assert out["BackupName"] == "daily"
    assert out["BackupStatus"] == "AVAILABLE"
    assert out["BackupType"] == "USER"
    assert out["BackupSizeBytes"] > 0
    assert out["BackupArn"].startswith(
        f"arn:aws:dynamodb:us-east-1:000000000000:table/{seeded_table}/backup/"
    )


def test_create_backup_on_missing_table_returns_not_found(ddb):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.create_backup(TableName="nonexistent_bkp_xyz", BackupName="daily")
    assert ei.value.response["Error"]["Code"] == "ResourceNotFoundException"


def test_create_backup_short_backup_name_rejected(ddb, seeded_table):
    # AWS-real: BackupName has min length 3. boto3 enforces this
    # client-side, so the assertion is on the exception class rather
    # than a server-side error code.
    with pytest.raises((botocore.exceptions.ParamValidationError, botocore.exceptions.ClientError)):
        ddb.create_backup(TableName=seeded_table, BackupName="ab")


# ---------------------------------------------------------------------------
# ListBackups


def test_list_backups_includes_recent(ddb, seeded_table):
    arn = ddb.create_backup(TableName=seeded_table, BackupName="daily")["BackupDetails"]["BackupArn"]
    summaries = ddb.list_backups()["BackupSummaries"]
    arns = {s["BackupArn"] for s in summaries}
    assert arn in arns


def test_list_backups_filters_by_table_name(ddb):
    name1 = _unique_table("bkp1")
    name2 = _unique_table("bkp2")
    for name in (name1, name2):
        ddb.create_table(
            TableName=name,
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        ddb.create_backup(TableName=name, BackupName="bkb")
    try:
        out = ddb.list_backups(TableName=name1)["BackupSummaries"]
        names = {s["TableName"] for s in out}
        assert names == {name1}
    finally:
        for name in (name1, name2):
            ddb.delete_table(TableName=name)


def test_list_backups_pagination(ddb, seeded_table):
    for i in range(3):
        ddb.create_backup(TableName=seeded_table, BackupName=f"bk{i}")
    page1 = ddb.list_backups(TableName=seeded_table, Limit=2)
    assert len(page1["BackupSummaries"]) == 2
    assert "LastEvaluatedBackupArn" in page1
    page2 = ddb.list_backups(
        TableName=seeded_table, Limit=2,
        ExclusiveStartBackupArn=page1["LastEvaluatedBackupArn"],
    )
    assert len(page2["BackupSummaries"]) == 1
    # The two pages cover disjoint ARNs.
    arns1 = {s["BackupArn"] for s in page1["BackupSummaries"]}
    arns2 = {s["BackupArn"] for s in page2["BackupSummaries"]}
    assert arns1.isdisjoint(arns2)


# ---------------------------------------------------------------------------
# DescribeBackup


def test_describe_backup_returns_full_description(ddb, seeded_table):
    arn = ddb.create_backup(TableName=seeded_table, BackupName="d1n")["BackupDetails"]["BackupArn"]
    desc = ddb.describe_backup(BackupArn=arn)["BackupDescription"]
    assert desc["BackupDetails"]["BackupArn"] == arn
    assert desc["BackupDetails"]["BackupName"] == "d1n"
    assert desc["SourceTableDetails"]["TableName"] == seeded_table
    assert desc["SourceTableDetails"]["ItemCount"] == 3
    # KeySchema should be present.
    ks = desc["SourceTableDetails"]["KeySchema"]
    assert ks[0]["AttributeName"] == "id"


def test_describe_backup_missing_arn_returns_not_found(ddb, seeded_table):
    fake = f"arn:aws:dynamodb:us-east-1:000000000000:table/{seeded_table}/backup/00000000000000-deadbeef"
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.describe_backup(BackupArn=fake)
    assert ei.value.response["Error"]["Code"] == "BackupNotFoundException"


def test_describe_backup_invalid_arn_returns_validation(ddb):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.describe_backup(BackupArn="not-an-arn-at-all-padding-to-37-chars!")
    assert ei.value.response["Error"]["Code"] == "ValidationException"


# ---------------------------------------------------------------------------
# DeleteBackup


def test_delete_backup_returns_deleted_description(ddb, seeded_table):
    arn = ddb.create_backup(TableName=seeded_table, BackupName="to-delete")["BackupDetails"]["BackupArn"]
    desc = ddb.delete_backup(BackupArn=arn)["BackupDescription"]
    assert desc["BackupDetails"]["BackupStatus"] == "DELETED"
    # Listing no longer surfaces it.
    summaries = ddb.list_backups()["BackupSummaries"]
    assert arn not in {s["BackupArn"] for s in summaries}


def test_delete_backup_missing_returns_not_found(ddb, seeded_table):
    fake = f"arn:aws:dynamodb:us-east-1:000000000000:table/{seeded_table}/backup/00000000000000-deadbeef"
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.delete_backup(BackupArn=fake)
    assert ei.value.response["Error"]["Code"] == "BackupNotFoundException"


# ---------------------------------------------------------------------------
# Source-table independence + persistence


def test_backup_survives_source_table_delete(ddb, seeded_table):
    arn = ddb.create_backup(TableName=seeded_table, BackupName="orphan")["BackupDetails"]["BackupArn"]
    ddb.delete_table(TableName=seeded_table)
    # Backup is still listable + describable.
    desc = ddb.describe_backup(BackupArn=arn)["BackupDescription"]
    assert desc["BackupDetails"]["BackupArn"] == arn


def _spawn_nanostack(bin_path: str, data_dir: str, port: int) -> subprocess.Popen:
    proc = subprocess.Popen(
        [bin_path, "--port", str(port), "--data-dir", data_dir, "--services", "s3,dynamodb"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    import requests
    deadline = time.time() + 5
    url = f"http://127.0.0.1:{port}/"
    while time.time() < deadline:
        try:
            requests.get(url, timeout=1)
            return proc
        except requests.RequestException:
            time.sleep(0.1)
    proc.kill()
    raise AssertionError(f"nanostack did not bind :{port} within 5s")


# ---------------------------------------------------------------------------
# Phase 2: RestoreTableFromBackup


def test_restore_from_backup_round_trips_items(ddb, seeded_table):
    arn = ddb.create_backup(TableName=seeded_table, BackupName="snap")["BackupDetails"]["BackupArn"]
    # Corrupt the live table.
    ddb.put_item(TableName=seeded_table, Item={"id": {"S": "k0"}, "n": {"N": "999"}})
    target = _unique_table("restored")
    out = ddb.restore_table_from_backup(BackupArn=arn, TargetTableName=target)
    assert out["TableDescription"]["TableName"] == target
    try:
        # Every snapshotted item is present in the restored table.
        items = ddb.scan(TableName=target)["Items"]
        ids = sorted(it["id"]["S"] for it in items)
        assert ids == ["k0", "k1", "k2"]
        # And the restored k0 has the pre-corruption value.
        k0 = ddb.get_item(TableName=target, Key={"id": {"S": "k0"}})["Item"]
        assert k0["n"]["N"] == "0"
    finally:
        ddb.delete_table(TableName=target)


def test_restore_target_name_conflict_returns_in_use(ddb, seeded_table):
    arn = ddb.create_backup(TableName=seeded_table, BackupName="conflict")["BackupDetails"]["BackupArn"]
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.restore_table_from_backup(BackupArn=arn, TargetTableName=seeded_table)
    assert ei.value.response["Error"]["Code"] == "ResourceInUseException"


def test_restore_with_missing_backup_returns_not_found(ddb):
    fake = "arn:aws:dynamodb:us-east-1:000000000000:table/x/backup/00000000000000-deadbeef"
    target = _unique_table("nope")
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.restore_table_from_backup(BackupArn=fake, TargetTableName=target)
    assert ei.value.response["Error"]["Code"] == "BackupNotFoundException"


# ---------------------------------------------------------------------------
# Phase 2: PITR (UpdateContinuousBackups + DescribeContinuousBackups)


def test_describe_continuous_backups_default_disabled(ddb, seeded_table):
    out = ddb.describe_continuous_backups(TableName=seeded_table)["ContinuousBackupsDescription"]
    assert out["ContinuousBackupsStatus"] == "ENABLED"
    assert out["PointInTimeRecoveryDescription"]["PointInTimeRecoveryStatus"] == "DISABLED"


def test_enable_pitr_then_describe(ddb, seeded_table):
    out = ddb.update_continuous_backups(
        TableName=seeded_table,
        PointInTimeRecoverySpecification={"PointInTimeRecoveryEnabled": True},
    )["ContinuousBackupsDescription"]
    assert out["PointInTimeRecoveryDescription"]["PointInTimeRecoveryStatus"] == "ENABLED"
    assert "EarliestRestorableDateTime" in out["PointInTimeRecoveryDescription"]

    desc = ddb.describe_continuous_backups(TableName=seeded_table)["ContinuousBackupsDescription"]
    assert desc["PointInTimeRecoveryDescription"]["PointInTimeRecoveryStatus"] == "ENABLED"


def test_disable_pitr_after_enable(ddb, seeded_table):
    ddb.update_continuous_backups(
        TableName=seeded_table,
        PointInTimeRecoverySpecification={"PointInTimeRecoveryEnabled": True},
    )
    out = ddb.update_continuous_backups(
        TableName=seeded_table,
        PointInTimeRecoverySpecification={"PointInTimeRecoveryEnabled": False},
    )["ContinuousBackupsDescription"]
    assert out["PointInTimeRecoveryDescription"]["PointInTimeRecoveryStatus"] == "DISABLED"


def test_pitr_on_missing_table_returns_not_found(ddb):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.describe_continuous_backups(TableName="nonexistent_pitr_xyz")
    assert ei.value.response["Error"]["Code"] == "ResourceNotFoundException"


# ---------------------------------------------------------------------------
# Phase 2: RestoreTableToPointInTime


def test_restore_to_point_in_time_snapshots_current(ddb, seeded_table):
    # NOTE: nanostack's PITR restore ignores RestoreDateTime and
    # snapshots the current table state. Documented divergence from
    # AWS-real (which would time-travel to the target).
    target = _unique_table("pit")
    out = ddb.restore_table_to_point_in_time(
        SourceTableName=seeded_table,
        TargetTableName=target,
        UseLatestRestorableTime=True,
    )
    try:
        assert out["TableDescription"]["TableName"] == target
        items = ddb.scan(TableName=target)["Items"]
        ids = sorted(it["id"]["S"] for it in items)
        assert ids == ["k0", "k1", "k2"]
    finally:
        ddb.delete_table(TableName=target)


def test_restore_to_point_in_time_target_conflict(ddb, seeded_table):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.restore_table_to_point_in_time(
            SourceTableName=seeded_table,
            TargetTableName=seeded_table,
            UseLatestRestorableTime=True,
        )
    assert ei.value.response["Error"]["Code"] == "ResourceInUseException"


def test_backup_persists_across_restart():
    bin_path = os.environ.get("NANOSTACK_BIN")
    if not bin_path:
        pytest.skip("NANOSTACK_BIN not set; skipping restart conformance test")

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    data_dir = tempfile.mkdtemp(prefix="ns-bkp-restart-")
    ep = f"http://127.0.0.1:{port}"
    name = _unique_table("persist")
    backup_arn: str = ""

    proc = _spawn_nanostack(bin_path, data_dir, port)
    try:
        ddb = _make_ddb(ep)
        ddb.create_table(
            TableName=name,
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        ddb.put_item(TableName=name, Item={"id": {"S": "p1"}})
        backup_arn = ddb.create_backup(TableName=name, BackupName="persist")["BackupDetails"]["BackupArn"]
    finally:
        proc.kill()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass

    proc2 = _spawn_nanostack(bin_path, data_dir, port)
    try:
        ddb = _make_ddb(ep)
        # Backup still listable + describable after restart.
        summaries = ddb.list_backups()["BackupSummaries"]
        assert backup_arn in {s["BackupArn"] for s in summaries}
        desc = ddb.describe_backup(BackupArn=backup_arn)["BackupDescription"]
        assert desc["SourceTableDetails"]["ItemCount"] == 1
    finally:
        proc2.kill()
        try:
            proc2.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        import shutil
        shutil.rmtree(data_dir, ignore_errors=True)
