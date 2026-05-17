"""ACL (bucket + object) conformance."""

import pytest
from botocore.exceptions import ClientError

from conftest import (
    aws_error_code,
    aws_http_status,
    best_effort_delete_bucket,
    drain_versions,
    empty_bucket,
    seed_object,
    sign_and_send,
)


def _has_grant(grants, predicate):
    return any(predicate(g) for g in grants or [])


def test_acl_bucket_round_trip_xml_body(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_bucket_acl(
            Bucket=bucket_name,
            AccessControlPolicy={
                "Owner": {"ID": "0123abc", "DisplayName": "owner"},
                "Grants": [
                    {
                        "Grantee": {
                            "Type": "CanonicalUser",
                            "ID": "0123abc",
                            "DisplayName": "owner",
                        },
                        "Permission": "FULL_CONTROL",
                    },
                    {
                        "Grantee": {
                            "Type": "Group",
                            "URI": "http://acs.amazonaws.com/groups/global/AllUsers",
                        },
                        "Permission": "READ",
                    },
                ],
            },
        )
        out = s3.get_bucket_acl(Bucket=bucket_name)
        assert out["Owner"].get("ID") == "0123abc", (
            f"owner mismatch: {out['Owner'].get('ID')}"
        )
        has_group = _has_grant(
            out.get("Grants", []),
            lambda g: g.get("Grantee", {}).get("Type") == "Group"
            and g.get("Grantee", {}).get("URI")
            == "http://acs.amazonaws.com/groups/global/AllUsers",
        )
        assert has_group, f"missing AllUsers Group grant: {out.get('Grants')}"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_acl_bucket_canned_header(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_bucket_acl(Bucket=bucket_name, ACL="public-read")
        out = s3.get_bucket_acl(Bucket=bucket_name)
        has_group = _has_grant(
            out.get("Grants", []),
            lambda g: g.get("Grantee", {}).get("Type") == "Group"
            and g.get("Permission") == "READ",
        )
        assert has_group, (
            f"canned public-read missing AllUsers READ: {out.get('Grants')}"
        )
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_acl_object_round_trip(s3, bucket_name):
    seed_object(s3, bucket_name, "k", b"v")
    try:
        s3.put_object_acl(Bucket=bucket_name, Key="k", ACL="public-read")
        out = s3.get_object_acl(Bucket=bucket_name, Key="k")
        has_group = _has_grant(
            out.get("Grants", []),
            lambda g: g.get("Grantee", {}).get("Type") == "Group",
        )
        assert has_group, f"object ACL missing Group grant: {out.get('Grants')}"
    finally:
        try:
            s3.delete_object(Bucket=bucket_name, Key="k")
        except ClientError:
            pass
        best_effort_delete_bucket(s3, bucket_name)


def test_acl_default_on_untouched_object(s3, bucket_name):
    seed_object(s3, bucket_name, "k", b"v")
    try:
        out = s3.get_object_acl(Bucket=bucket_name, Key="k")
        grants = out.get("Grants", []) or []
        assert (
            len(grants) == 1 and grants[0].get("Permission") == "FULL_CONTROL"
        ), f"expected single FULL_CONTROL grant, got: {grants}"
    finally:
        try:
            s3.delete_object(Bucket=bucket_name, Key="k")
        except ClientError:
            pass
        best_effort_delete_bucket(s3, bucket_name)


def test_acl_put_object_inline_canned_header(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_object(Bucket=bucket_name, Key="k", Body=b"hi", ACL="public-read")
        out = s3.get_object_acl(Bucket=bucket_name, Key="k")
        has_group = _has_grant(
            out.get("Grants", []),
            lambda g: g.get("Grantee", {}).get("Type") == "Group",
        )
        assert has_group, f"inline ACL didn't land: {out.get('Grants')}"
    finally:
        try:
            s3.delete_object(Bucket=bucket_name, Key="k")
        except ClientError:
            pass
        best_effort_delete_bucket(s3, bucket_name)


def test_acl_grant_header_folds_into_acl(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_object(
            Bucket=bucket_name,
            Key="k",
            Body=b"hi",
            GrantRead='id="abc-canonical"',
        )
        out = s3.get_object_acl(Bucket=bucket_name, Key="k")
        has_read = _has_grant(
            out.get("Grants", []),
            lambda g: g.get("Permission") == "READ"
            and g.get("Grantee", {}).get("ID") == "abc-canonical",
        )
        assert has_read, (
            f"expected READ grant for abc-canonical, got: {out.get('Grants')}"
        )
    finally:
        try:
            s3.delete_object(Bucket=bucket_name, Key="k")
        except ClientError:
            pass
        best_effort_delete_bucket(s3, bucket_name)


def test_acl_bucket_owner_enforced_rejects_acl_put(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_bucket_ownership_controls(
            Bucket=bucket_name,
            OwnershipControls={
                "Rules": [{"ObjectOwnership": "BucketOwnerEnforced"}]
            },
        )
        with pytest.raises(ClientError) as ei:
            s3.put_bucket_acl(Bucket=bucket_name, ACL="private")
        assert aws_error_code(ei.value) == "AccessControlListNotSupported"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_acl_per_version(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_bucket_versioning(
            Bucket=bucket_name,
            VersioningConfiguration={"Status": "Enabled"},
        )

        v1 = s3.put_object(Bucket=bucket_name, Key="k", Body=b"first")
        v2 = s3.put_object(Bucket=bucket_name, Key="k", Body=b"second")

        # Tag v1 ACL as public-read.
        s3.put_object_acl(
            Bucket=bucket_name,
            Key="k",
            VersionId=v1["VersionId"],
            ACL="public-read",
        )
        out1 = s3.get_object_acl(
            Bucket=bucket_name, Key="k", VersionId=v1["VersionId"]
        )
        has_group_1 = _has_grant(
            out1.get("Grants", []),
            lambda g: g.get("Grantee", {}).get("Type") == "Group",
        )
        assert has_group_1, (
            f"v1 should have AllUsers grant, got: {out1.get('Grants')}"
        )
        out2 = s3.get_object_acl(
            Bucket=bucket_name, Key="k", VersionId=v2["VersionId"]
        )
        has_group_2 = _has_grant(
            out2.get("Grants", []),
            lambda g: g.get("Grantee", {}).get("Type") == "Group",
        )
        assert not has_group_2, (
            f"v2 should NOT have AllUsers grant, got: {out2.get('Grants')}"
        )
    finally:
        drain_versions(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_acl_malformed_xml_400(s3, bucket_name):
    # Send an UNKNOWN canned value to trigger InvalidArgument. boto3 strict
    # validation rejects unknown ACL enum values, so we must use raw HTTP.
    s3.create_bucket(Bucket=bucket_name)
    try:
        resp = sign_and_send(
            "PUT",
            f"/{bucket_name}?acl",
            headers={"x-amz-acl": "frobnicate"},
        )
        assert resp.status_code == 400, f"expected 400, got {resp.status_code}"
    finally:
        best_effort_delete_bucket(s3, bucket_name)
