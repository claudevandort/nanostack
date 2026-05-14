"""Basic NotImplemented contract for un-mapped operations.

M13 routed RestoreObject (formerly the sentinel); the new sentinel is
GetObjectTorrent — an AWS-deprecated op that stays unrouted indefinitely.
"""

import pytest
from botocore.exceptions import ClientError

from conftest import aws_error_code, aws_http_status, best_effort_delete_bucket


def test_unrouted_operation_returns_not_implemented(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        with pytest.raises(ClientError) as ei:
            # GetObjectTorrent (GET /bucket/key?torrent) is AWS-deprecated —
            # the router routes ?torrent to .unknown and the service layer
            # returns 501 NotImplemented.
            s3.get_object_torrent(Bucket=bucket_name, Key="k")
        assert aws_error_code(ei.value) == "NotImplemented"
        assert aws_http_status(ei.value) == 501
    finally:
        best_effort_delete_bucket(s3, bucket_name)
