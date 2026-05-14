"""ListMultipartUploads / ListParts conformance."""

from botocore.exceptions import ClientError

from conftest import (
    best_effort_delete_bucket,
    empty_bucket,
)


def test_multipart_list_multipart_uploads_basic(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    keys = ["alpha", "beta", "gamma"]
    upload_ids: list[str] = []
    try:
        for k in keys:
            init = s3.create_multipart_upload(Bucket=bucket_name, Key=k)
            upload_ids.append(init["UploadId"])

        out = s3.list_multipart_uploads(Bucket=bucket_name)
        uploads = out.get("Uploads", []) or []
        assert len(uploads) == 3, f"expected 3 uploads, got {len(uploads)}"
        got_keys = [u["Key"] for u in uploads]
        assert got_keys == sorted(got_keys), f"uploads not sorted by key: {got_keys}"
    finally:
        for i, k in enumerate(keys):
            if i < len(upload_ids):
                try:
                    s3.abort_multipart_upload(Bucket=bucket_name, Key=k, UploadId=upload_ids[i])
                except ClientError:
                    pass
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_multipart_list_multipart_uploads_pagination(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    keys = ["k1", "k2", "k3", "k4", "k5"]
    upload_ids: list[str] = []
    try:
        for k in keys:
            init = s3.create_multipart_upload(Bucket=bucket_name, Key=k)
            upload_ids.append(init["UploadId"])

        seen: list[str] = []
        key_marker = None
        id_marker = None
        pages = 0
        while True:
            pages += 1
            kwargs = {"Bucket": bucket_name, "MaxUploads": 2}
            if key_marker is not None:
                kwargs["KeyMarker"] = key_marker
            if id_marker is not None:
                kwargs["UploadIdMarker"] = id_marker
            out = s3.list_multipart_uploads(**kwargs)
            for u in out.get("Uploads", []) or []:
                seen.append(u["Key"])
            if not out.get("IsTruncated", False):
                break
            key_marker = out.get("NextKeyMarker")
            id_marker = out.get("NextUploadIdMarker")
            assert pages <= 10, "too many pages"
        assert pages == 3, f"expected 3 pages, got {pages}"
        seen.sort()
        for i, k in enumerate(keys):
            assert seen[i] == k, f"page mismatch at {i}: got {seen[i]!r} want {k!r}"
    finally:
        for i, k in enumerate(keys):
            if i < len(upload_ids):
                try:
                    s3.abort_multipart_upload(Bucket=bucket_name, Key=k, UploadId=upload_ids[i])
                except ClientError:
                    pass
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_multipart_list_parts_pagination(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    upload_id = None
    try:
        init = s3.create_multipart_upload(Bucket=bucket_name, Key="k")
        upload_id = init["UploadId"]

        for i in range(1, 6):
            s3.upload_part(
                Bucket=bucket_name, Key="k", UploadId=upload_id,
                PartNumber=i, Body=b"x",
            )

        seen: list[int] = []
        marker = None
        pages = 0
        while True:
            pages += 1
            kwargs = {
                "Bucket": bucket_name, "Key": "k", "UploadId": upload_id,
                "MaxParts": 2,
            }
            if marker is not None:
                kwargs["PartNumberMarker"] = marker
            out = s3.list_parts(**kwargs)
            for p in out.get("Parts", []) or []:
                seen.append(p["PartNumber"])
            if not out.get("IsTruncated", False):
                break
            marker = out.get("NextPartNumberMarker")
            assert pages <= 10, "too many pages"
        assert pages == 3, f"expected 3 pages, got {pages}"
        assert len(seen) == 5, f"expected 5 parts total, got {len(seen)}"
    finally:
        if upload_id is not None:
            try:
                s3.abort_multipart_upload(Bucket=bucket_name, Key="k", UploadId=upload_id)
            except ClientError:
                pass
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)
