"""ListObjects / ListObjectsV2 conformance."""

from conftest import (
    best_effort_delete_bucket,
    empty_bucket,
    unique_bucket,
)


def _seed_bucket_with_objects(s3, bucket: str, keys: list[str]) -> None:
    s3.create_bucket(Bucket=bucket)
    for k in keys:
        s3.put_object(Bucket=bucket, Key=k, Body=b"v")


def test_list_objects_v2_empty_bucket(s3, request):
    bucket = unique_bucket("lov2e", suffix=request.node.name)
    _seed_bucket_with_objects(s3, bucket, [])
    try:
        out = s3.list_objects_v2(Bucket=bucket)
        assert out.get("KeyCount") == 0, f"KeyCount: got {out.get('KeyCount')} want 0"
        assert not out.get("IsTruncated", False), "expected !IsTruncated"
    finally:
        best_effort_delete_bucket(s3, bucket)


def test_list_objects_v2_all_keys(s3, request):
    bucket = unique_bucket("lov2a", suffix=request.node.name)
    keys = ["alpha", "beta", "gamma", "delta", "epsilon"]
    _seed_bucket_with_objects(s3, bucket, keys)
    try:
        out = s3.list_objects_v2(Bucket=bucket)
        contents = out.get("Contents", []) or []
        assert len(contents) == len(keys), f"expected {len(keys)} contents, got {len(contents)}"
        got_keys = [c["Key"] for c in contents]
        assert got_keys == sorted(got_keys), f"response not sorted: {got_keys}"
    finally:
        empty_bucket(s3, bucket)
        best_effort_delete_bucket(s3, bucket)


def test_list_objects_v2_prefix(s3, request):
    bucket = unique_bucket("lov2p", suffix=request.node.name)
    keys = ["foo/a", "foo/b", "bar/c"]
    _seed_bucket_with_objects(s3, bucket, keys)
    try:
        out = s3.list_objects_v2(Bucket=bucket, Prefix="foo/")
        contents = out.get("Contents", []) or []
        assert len(contents) == 2, f"expected 2 contents, got {len(contents)}"
        for obj in contents:
            assert obj["Key"].startswith("foo/"), f"unexpected key {obj['Key']!r}"
    finally:
        empty_bucket(s3, bucket)
        best_effort_delete_bucket(s3, bucket)


def test_list_objects_v2_delimiter(s3, request):
    bucket = unique_bucket("lov2d", suffix=request.node.name)
    keys = ["a/1", "a/2", "b/3", "c"]
    _seed_bucket_with_objects(s3, bucket, keys)
    try:
        out = s3.list_objects_v2(Bucket=bucket, Delimiter="/")
        contents = out.get("Contents", []) or []
        common = out.get("CommonPrefixes", []) or []
        # Expect Contents=[c], CommonPrefixes=[a/, b/]
        assert len(contents) == 1, f"expected 1 content, got {len(contents)}"
        assert len(common) == 2, f"expected 2 common prefixes, got {len(common)}"
        cps = sorted([common[0]["Prefix"], common[1]["Prefix"]])
        assert cps[0] == "a/" and cps[1] == "b/", f"unexpected CommonPrefixes: {cps}"
    finally:
        empty_bucket(s3, bucket)
        best_effort_delete_bucket(s3, bucket)


def test_list_objects_v2_pagination(s3, request):
    bucket = unique_bucket("lov2page", suffix=request.node.name)
    keys = ["k1", "k2", "k3", "k4", "k5"]
    _seed_bucket_with_objects(s3, bucket, keys)
    try:
        seen: list[str] = []
        token = None
        pages = 0
        while True:
            pages += 1
            kwargs = {"Bucket": bucket, "MaxKeys": 2}
            if token is not None:
                kwargs["ContinuationToken"] = token
            out = s3.list_objects_v2(**kwargs)
            for obj in out.get("Contents", []) or []:
                seen.append(obj["Key"])
            if not out.get("IsTruncated", False):
                break
            token = out.get("NextContinuationToken")
            assert pages <= 10, "too many pages"
        assert pages == 3, f"expected 3 pages (2+2+1), got {pages}"
        seen.sort()
        for i, k in enumerate(keys):
            assert seen[i] == k, f"page set mismatch at {i}: got {seen[i]!r} want {k!r}"
    finally:
        empty_bucket(s3, bucket)
        best_effort_delete_bucket(s3, bucket)


def test_list_objects_v2_start_after(s3, request):
    bucket = unique_bucket("lov2sa", suffix=request.node.name)
    keys = ["a", "b", "c", "d"]
    _seed_bucket_with_objects(s3, bucket, keys)
    try:
        out = s3.list_objects_v2(Bucket=bucket, StartAfter="b")
        contents = out.get("Contents", []) or []
        assert len(contents) == 2, f"expected 2 contents after 'b', got {len(contents)}"
        assert contents[0]["Key"] == "c" and contents[1]["Key"] == "d", f"got {contents}"
    finally:
        empty_bucket(s3, bucket)
        best_effort_delete_bucket(s3, bucket)


def test_list_objects_v1_marker(s3, request):
    bucket = unique_bucket("lov1m", suffix=request.node.name)
    keys = ["a", "b", "c", "d"]
    _seed_bucket_with_objects(s3, bucket, keys)
    try:
        out = s3.list_objects(Bucket=bucket, Marker="b")
        contents = out.get("Contents", []) or []
        assert len(contents) == 2, f"expected 2 contents after marker 'b', got {len(contents)}"
        assert contents[0]["Key"] == "c" and contents[1]["Key"] == "d", f"got {contents}"
    finally:
        empty_bucket(s3, bucket)
        best_effort_delete_bucket(s3, bucket)
