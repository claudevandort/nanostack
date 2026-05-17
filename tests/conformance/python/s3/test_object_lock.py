"""Object Lock + retention + legal hold conformance."""

import datetime

import pytest
from botocore.exceptions import ClientError

from conftest import (
    aws_error_code,
    best_effort_delete_bucket,
    drain_versions,
)


def _create_locked_bucket(s3, name):
    """Create a bucket with Object Lock enabled (auto-enables versioning)."""
    s3.create_bucket(Bucket=name, ObjectLockEnabledForBucket=True)


def _put_with_governance(s3, bucket, key):
    """Put object with GOVERNANCE retention 1 day from now, return version id."""
    until = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1)
    out = s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=b"locked",
        ObjectLockMode="GOVERNANCE",
        ObjectLockRetainUntilDate=until,
    )
    return out["VersionId"]


def test_object_lock_create_bucket_auto_enables_versioning(s3, bucket_name):
    _create_locked_bucket(s3, bucket_name)
    try:
        out = s3.get_bucket_versioning(Bucket=bucket_name)
        assert out.get("Status") == "Enabled", (
            f"expected versioning Enabled, got {out.get('Status')!r}"
        )
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_object_lock_suspend_rejected(s3, bucket_name):
    _create_locked_bucket(s3, bucket_name)
    try:
        with pytest.raises(ClientError) as ei:
            s3.put_bucket_versioning(
                Bucket=bucket_name,
                VersioningConfiguration={"Status": "Suspended"},
            )
        assert aws_error_code(ei.value) == "InvalidBucketState"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_object_lock_put_config_on_non_locked_bucket_rejected(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        with pytest.raises(ClientError) as ei:
            s3.put_object_lock_configuration(
                Bucket=bucket_name,
                ObjectLockConfiguration={"ObjectLockEnabled": "Enabled"},
            )
        assert aws_error_code(ei.value) == "InvalidBucketState"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_object_lock_config_round_trip(s3, bucket_name):
    _create_locked_bucket(s3, bucket_name)
    try:
        s3.put_object_lock_configuration(
            Bucket=bucket_name,
            ObjectLockConfiguration={
                "ObjectLockEnabled": "Enabled",
                "Rule": {
                    "DefaultRetention": {"Mode": "GOVERNANCE", "Days": 1}
                },
            },
        )
        out = s3.get_object_lock_configuration(Bucket=bucket_name)
        rule = out["ObjectLockConfiguration"]["Rule"]
        assert rule["DefaultRetention"]["Mode"] == "GOVERNANCE", "mode mismatch"
        assert rule["DefaultRetention"]["Days"] == 1, "days mismatch"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_object_lock_get_config_bare_enabled(s3, bucket_name):
    _create_locked_bucket(s3, bucket_name)
    try:
        out = s3.get_object_lock_configuration(Bucket=bucket_name)
        assert out["ObjectLockConfiguration"]["ObjectLockEnabled"] == "Enabled", (
            f"expected Enabled, got {out['ObjectLockConfiguration']['ObjectLockEnabled']!r}"
        )
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_object_lock_retention_round_trip(s3, bucket_name):
    _create_locked_bucket(s3, bucket_name)
    try:
        vid = _put_with_governance(s3, bucket_name, "k")
        out = s3.get_object_retention(Bucket=bucket_name, Key="k", VersionId=vid)
        assert out["Retention"]["Mode"] == "GOVERNANCE", "mode mismatch"
    finally:
        drain_versions(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_object_lock_delete_within_governance_access_denied(s3, bucket_name):
    _create_locked_bucket(s3, bucket_name)
    try:
        vid = _put_with_governance(s3, bucket_name, "k")
        with pytest.raises(ClientError) as ei:
            s3.delete_object(Bucket=bucket_name, Key="k", VersionId=vid)
        assert aws_error_code(ei.value) == "AccessDenied"
    finally:
        # Drain with bypass so cleanup succeeds.
        try:
            lst = s3.list_object_versions(Bucket=bucket_name)
            for v in lst.get("Versions", []) or []:
                try:
                    s3.delete_object(
                        Bucket=bucket_name,
                        Key=v["Key"],
                        VersionId=v["VersionId"],
                        BypassGovernanceRetention=True,
                    )
                except ClientError:
                    pass
            for m in lst.get("DeleteMarkers", []) or []:
                try:
                    s3.delete_object(
                        Bucket=bucket_name, Key=m["Key"], VersionId=m["VersionId"]
                    )
                except ClientError:
                    pass
        except ClientError:
            pass
        best_effort_delete_bucket(s3, bucket_name)


def test_object_lock_delete_with_bypass_ok(s3, bucket_name):
    _create_locked_bucket(s3, bucket_name)
    try:
        vid = _put_with_governance(s3, bucket_name, "k")
        s3.delete_object(
            Bucket=bucket_name, Key="k", VersionId=vid, BypassGovernanceRetention=True
        )
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_object_lock_compliance_bypass_still_blocked(s3, bucket_name):
    _create_locked_bucket(s3, bucket_name)
    try:
        until = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1)
        out = s3.put_object(
            Bucket=bucket_name,
            Key="k",
            Body=b"x",
            ObjectLockMode="COMPLIANCE",
            ObjectLockRetainUntilDate=until,
        )
        vid = out["VersionId"]
        with pytest.raises(ClientError) as ei:
            s3.delete_object(
                Bucket=bucket_name,
                Key="k",
                VersionId=vid,
                BypassGovernanceRetention=True,
            )
        assert aws_error_code(ei.value) == "AccessDenied"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_object_lock_legal_hold_blocks_delete(s3, bucket_name):
    _create_locked_bucket(s3, bucket_name)
    try:
        out = s3.put_object(
            Bucket=bucket_name,
            Key="k",
            Body=b"hold",
            ObjectLockLegalHoldStatus="ON",
        )
        vid = out["VersionId"]

        # Delete should be blocked even with bypass (legal hold supersedes).
        with pytest.raises(ClientError):
            s3.delete_object(
                Bucket=bucket_name,
                Key="k",
                VersionId=vid,
                BypassGovernanceRetention=True,
            )

        # Turn off legal hold.
        s3.put_object_legal_hold(
            Bucket=bucket_name,
            Key="k",
            VersionId=vid,
            LegalHold={"Status": "OFF"},
        )

        # Now delete should succeed.
        s3.delete_object(Bucket=bucket_name, Key="k", VersionId=vid)
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_object_lock_legal_hold_round_trip(s3, bucket_name):
    _create_locked_bucket(s3, bucket_name)
    try:
        out = s3.put_object(Bucket=bucket_name, Key="k", Body=b"x")
        vid = out["VersionId"]
        try:
            s3.put_object_legal_hold(
                Bucket=bucket_name,
                Key="k",
                VersionId=vid,
                LegalHold={"Status": "ON"},
            )
            hold = s3.get_object_legal_hold(
                Bucket=bucket_name, Key="k", VersionId=vid
            )
            assert hold["LegalHold"]["Status"] == "ON", (
                f"expected ON, got {hold['LegalHold']['Status']!r}"
            )
        finally:
            # Turn legal hold off so cleanup can succeed.
            try:
                s3.put_object_legal_hold(
                    Bucket=bucket_name,
                    Key="k",
                    VersionId=vid,
                    LegalHold={"Status": "OFF"},
                )
            except ClientError:
                pass
            try:
                s3.delete_object(Bucket=bucket_name, Key="k", VersionId=vid)
            except ClientError:
                pass
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_object_lock_inline_headers_round_trip(s3, bucket_name):
    _create_locked_bucket(s3, bucket_name)
    try:
        vid = _put_with_governance(s3, bucket_name, "k")
        try:
            head = s3.head_object(Bucket=bucket_name, Key="k", VersionId=vid)
            assert head.get("ObjectLockMode") == "GOVERNANCE", (
                f"expected GOVERNANCE in HEAD response, got {head.get('ObjectLockMode')!r}"
            )
        finally:
            try:
                s3.delete_object(
                    Bucket=bucket_name,
                    Key="k",
                    VersionId=vid,
                    BypassGovernanceRetention=True,
                )
            except ClientError:
                pass
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_object_lock_default_retention_applied(s3, bucket_name):
    _create_locked_bucket(s3, bucket_name)
    try:
        s3.put_object_lock_configuration(
            Bucket=bucket_name,
            ObjectLockConfiguration={
                "ObjectLockEnabled": "Enabled",
                "Rule": {"DefaultRetention": {"Mode": "GOVERNANCE", "Days": 1}},
            },
        )
        out = s3.put_object(Bucket=bucket_name, Key="k", Body=b"x")
        vid = out["VersionId"]
        try:
            r = s3.get_object_retention(Bucket=bucket_name, Key="k", VersionId=vid)
            assert r["Retention"]["Mode"] == "GOVERNANCE", (
                f"expected GOVERNANCE from default rule, got {r['Retention']['Mode']!r}"
            )
        finally:
            try:
                s3.delete_object(
                    Bucket=bucket_name,
                    Key="k",
                    VersionId=vid,
                    BypassGovernanceRetention=True,
                )
            except ClientError:
                pass
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_object_lock_delete_marker_allowed_on_locked(s3, bucket_name):
    _create_locked_bucket(s3, bucket_name)
    try:
        vid = _put_with_governance(s3, bucket_name, "k")
        try:
            # Delete WITHOUT versionId — should create a delete marker, NOT block.
            s3.delete_object(Bucket=bucket_name, Key="k")
        finally:
            try:
                s3.delete_object(
                    Bucket=bucket_name,
                    Key="k",
                    VersionId=vid,
                    BypassGovernanceRetention=True,
                )
            except ClientError:
                pass
            # Drain leftover delete markers.
            try:
                lst = s3.list_object_versions(Bucket=bucket_name)
                for m in lst.get("DeleteMarkers", []) or []:
                    try:
                        s3.delete_object(
                            Bucket=bucket_name,
                            Key=m["Key"],
                            VersionId=m["VersionId"],
                        )
                    except ClientError:
                        pass
            except ClientError:
                pass
    finally:
        best_effort_delete_bucket(s3, bucket_name)
