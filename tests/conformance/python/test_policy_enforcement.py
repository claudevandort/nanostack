"""Real ACL + bucket policy + PAB enforcement (M14).

These tests verify that nanostack's authz hook actually consults the
persisted policy/ACL/PAB state, rather than accepting puts and ignoring
them. Anonymous reads, owner-affecting Deny statements, PAB admission
gates, and PAB eval-time filters all exercise the same orchestrator.
"""

from __future__ import annotations

import json

import botocore.exceptions
import pytest
import requests

from conftest import (
    aws_error_code,
    aws_http_status,
    best_effort_delete_bucket,
    empty_bucket,
    endpoint,
    seed_object,
)


# ---------------------------------------------------------------------------
# Helpers

def anon_get(bucket: str, key: str = "") -> requests.Response:
    """Unsigned GET via path-style — exercises the anonymous-principal path."""
    suffix = f"/{key}" if key else ""
    return requests.get(f"{endpoint()}/{bucket}{suffix}", timeout=5)


def _put_public_read_policy(s3, bucket: str, key_glob: str = "*") -> None:
    policy = {
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": f"arn:aws:s3:::{bucket}/{key_glob}",
        }],
    }
    s3.put_bucket_policy(Bucket=bucket, Policy=json.dumps(policy))


# ---------------------------------------------------------------------------
# Anonymous + public-read

def test_anonymous_get_on_public_read_object_acl_returns_200(s3, bucket_name):
    """Set per-object canned ACL public-read — anonymous GET → 200.
    (Bucket-level public-read only grants ListBucket; AWS-correct.)"""
    seed_object(s3, bucket_name, "k", body=b"hello")
    s3.put_object_acl(Bucket=bucket_name, Key="k", ACL="public-read")
    try:
        resp = anon_get(bucket_name, "k")
        assert resp.status_code == 200
        assert resp.content == b"hello"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_anonymous_get_on_private_bucket_returns_403(s3, bucket_name):
    """Default bucket (no policy, no public ACL); anonymous GET → 403."""
    seed_object(s3, bucket_name, "k")
    try:
        resp = anon_get(bucket_name, "k")
        assert resp.status_code == 403
        assert "<Code>AccessDenied</Code>" in resp.text
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_anonymous_get_on_public_read_policy_returns_200(s3, bucket_name):
    """Allow s3:GetObject Principal:* on arn:.../<bucket>/* — anonymous → 200."""
    seed_object(s3, bucket_name, "k", body=b"v")
    _put_public_read_policy(s3, bucket_name)
    try:
        resp = anon_get(bucket_name, "k")
        assert resp.status_code == 200
        assert resp.content == b"v"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


# ---------------------------------------------------------------------------
# Owner-affecting Deny

def test_bucket_policy_explicit_deny_against_owner(s3, bucket_name):
    """Explicit Deny on s3:DeleteObject Principal:* — owner delete → 403."""
    seed_object(s3, bucket_name, "k")
    policy = {
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Deny",
            "Principal": "*",
            "Action": "s3:DeleteObject",
            "Resource": f"arn:aws:s3:::{bucket_name}/*",
        }],
    }
    s3.put_bucket_policy(Bucket=bucket_name, Policy=json.dumps(policy))
    try:
        with pytest.raises(botocore.exceptions.ClientError) as ei:
            s3.delete_object(Bucket=bucket_name, Key="k")
        assert aws_http_status(ei.value) == 403
        assert aws_error_code(ei.value) == "AccessDenied"
    finally:
        # Need to clean up: delete the policy first or the cleanup itself 403's.
        try:
            s3.delete_bucket_policy(Bucket=bucket_name)
        except botocore.exceptions.ClientError:
            pass
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_bucket_policy_explicit_deny_supersedes_allow(s3, bucket_name):
    """Allow s3:* then Deny s3:GetObject — anonymous GET → 403 (Deny wins)."""
    seed_object(s3, bucket_name, "k")
    policy = {
        "Version": "2012-10-17",
        "Statement": [
            {"Effect": "Allow", "Principal": "*", "Action": "s3:*",
             "Resource": f"arn:aws:s3:::{bucket_name}/*"},
            {"Effect": "Deny", "Principal": "*", "Action": "s3:GetObject",
             "Resource": f"arn:aws:s3:::{bucket_name}/*"},
        ],
    }
    s3.put_bucket_policy(Bucket=bucket_name, Policy=json.dumps(policy))
    try:
        resp = anon_get(bucket_name, "k")
        assert resp.status_code == 403
        assert "<Code>AccessDenied</Code>" in resp.text
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


# ---------------------------------------------------------------------------
# PAB admission gates (put-time)

def test_pab_block_public_policy_rejects_public_put(s3, bucket_name):
    """BlockPublicPolicy on — PutBucketPolicy with Principal:* → 403."""
    s3.create_bucket(Bucket=bucket_name)
    s3.put_public_access_block(
        Bucket=bucket_name,
        PublicAccessBlockConfiguration={
            "BlockPublicAcls": False,
            "IgnorePublicAcls": False,
            "BlockPublicPolicy": True,
            "RestrictPublicBuckets": False,
        },
    )
    try:
        with pytest.raises(botocore.exceptions.ClientError) as ei:
            _put_public_read_policy(s3, bucket_name)
        assert aws_http_status(ei.value) == 403
        assert aws_error_code(ei.value) == "AccessDenied"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_pab_block_public_acls_rejects_public_acl_put(s3, bucket_name):
    """BlockPublicAcls on — put-bucket-acl public-read → 403."""
    s3.create_bucket(Bucket=bucket_name)
    s3.put_public_access_block(
        Bucket=bucket_name,
        PublicAccessBlockConfiguration={
            "BlockPublicAcls": True,
            "IgnorePublicAcls": False,
            "BlockPublicPolicy": False,
            "RestrictPublicBuckets": False,
        },
    )
    try:
        with pytest.raises(botocore.exceptions.ClientError) as ei:
            s3.put_bucket_acl(Bucket=bucket_name, ACL="public-read")
        assert aws_http_status(ei.value) == 403
        assert aws_error_code(ei.value) == "AccessDenied"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


# ---------------------------------------------------------------------------
# PAB eval-time filters

def test_pab_ignore_public_acls_blocks_anonymous_get(s3, bucket_name):
    """public-read ACL set, then IgnorePublicAcls on — anonymous GET → 403."""
    seed_object(s3, bucket_name, "k")
    s3.put_bucket_acl(Bucket=bucket_name, ACL="public-read")
    s3.put_public_access_block(
        Bucket=bucket_name,
        PublicAccessBlockConfiguration={
            "BlockPublicAcls": False,
            "IgnorePublicAcls": True,
            "BlockPublicPolicy": False,
            "RestrictPublicBuckets": False,
        },
    )
    try:
        resp = anon_get(bucket_name, "k")
        assert resp.status_code == 403
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_pab_restrict_public_buckets_blocks_anonymous_via_policy(s3, bucket_name):
    """Public policy set, RestrictPublicBuckets on — anonymous → 403, owner → 200."""
    seed_object(s3, bucket_name, "k", body=b"v")
    _put_public_read_policy(s3, bucket_name)
    s3.put_public_access_block(
        Bucket=bucket_name,
        PublicAccessBlockConfiguration={
            "BlockPublicAcls": False,
            "IgnorePublicAcls": False,
            "BlockPublicPolicy": False,
            "RestrictPublicBuckets": True,
        },
    )
    try:
        # Anonymous denied (public statement filtered out).
        anon = anon_get(bucket_name, "k")
        assert anon.status_code == 403
        # Owner still gets it (owner bypasses RestrictPublicBuckets).
        out = s3.get_object(Bucket=bucket_name, Key="k")
        assert out["Body"].read() == b"v"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


# ---------------------------------------------------------------------------
# Documented divergences

def test_policy_with_condition_block_is_skipped(s3, bucket_name):
    """v1 divergence: statements with Condition are silently skipped."""
    seed_object(s3, bucket_name, "k")
    policy = {
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": f"arn:aws:s3:::{bucket_name}/*",
            "Condition": {"StringEquals": {"aws:Referer": "https://example.com"}},
        }],
    }
    s3.put_bucket_policy(Bucket=bucket_name, Policy=json.dumps(policy))
    try:
        # Condition causes the statement to be ignored → anonymous denied.
        resp = anon_get(bucket_name, "k")
        assert resp.status_code == 403
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


# ---------------------------------------------------------------------------
# GetBucketPolicyStatus via the real evaluator

def test_get_bucket_policy_status_reflects_real_evaluator(s3, bucket_name):
    """IsPublic flips correctly for Allow Principal:* vs Allow {AWS: owner}."""
    s3.create_bucket(Bucket=bucket_name)
    try:
        # Public-Allow → IsPublic = true.
        _put_public_read_policy(s3, bucket_name)
        out = s3.get_bucket_policy_status(Bucket=bucket_name)
        assert out["PolicyStatus"]["IsPublic"] is True

        # Replace with specific-principal Allow → IsPublic = false.
        private = {
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {"AWS": "test"},
                "Action": "s3:GetObject",
                "Resource": f"arn:aws:s3:::{bucket_name}/*",
            }],
        }
        s3.put_bucket_policy(Bucket=bucket_name, Policy=json.dumps(private))
        out = s3.get_bucket_policy_status(Bucket=bucket_name)
        assert out["PolicyStatus"]["IsPublic"] is False
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)
