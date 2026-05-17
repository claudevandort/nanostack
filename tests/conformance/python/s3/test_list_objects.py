"""ListObjects / ListObjectsV2 conformance."""

from conftest import (
    best_effort_delete_bucket,
    empty_bucket,
    sign_and_send,
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


def test_list_objects_v2_encoding_type_url_percent_encodes_keys(s3, request):
    """AWS-exact: when ?encoding-type=url is set, all user-supplied text fields
    (Key, Prefix, Delimiter, NextMarker) are percent-encoded per RFC 3986.
    boto3 transparently decodes the body when EncodingType="url" is requested
    via the SDK — so we drop to raw signed HTTP to inspect the on-the-wire
    bytes. Drift table row 8.
    """
    bucket = unique_bucket(prefix="t", suffix="enc-url")
    # Use keys that round-trip cleanly through storage. (Keys with spaces
    # are stored URL-encoded today — a separate drift outside Wave 2 scope.)
    _seed_bucket_with_objects(s3, bucket, ["one", "two", "three"])
    try:
        import requests
        from botocore.awsrequest import AWSRequest
        from botocore.auth import SigV4Auth
        from conftest import aws_test_credentials, endpoint, endpoint_host, SHA256_EMPTY
        from urllib.parse import quote

        # Send prefix and delimiter that REQUIRE percent-encoding when echoed.
        prefix_q = quote("foo bar/", safe="")
        delim_q = quote("/", safe="")
        path = f"/{bucket}?delimiter={delim_q}&encoding-type=url&list-type=2&prefix={prefix_q}"

        req = AWSRequest(
            method="GET",
            url=endpoint() + path,
            data=b"",
            headers={"host": endpoint_host(), "x-amz-content-sha256": SHA256_EMPTY},
        )
        SigV4Auth(aws_test_credentials(), "s3", "us-east-1").add_auth(req)
        resp = requests.get(req.url, headers=dict(req.headers.items()), timeout=10)
        assert resp.status_code == 200, f"got {resp.status_code}: {resp.text}"
        body = resp.text

        # The Prefix echo should be percent-encoded (sent as "foo bar/").
        assert "<Prefix>foo%20bar%2F</Prefix>" in body, \
            f"prefix not percent-encoded; body: {body}"
        # The Delimiter echo (literal "/") should be %2F.
        assert "<Delimiter>%2F</Delimiter>" in body, \
            f"delimiter not percent-encoded; body: {body}"
        # EncodingType element echoes the literal token.
        assert "<EncodingType>url</EncodingType>" in body

        # Without encoding-type, the same field should NOT be encoded — confirms
        # `maybeEncode` is gated on the query param.
        path2 = f"/{bucket}?delimiter={delim_q}&list-type=2&prefix={prefix_q}"
        req2 = AWSRequest(
            method="GET", url=endpoint() + path2, data=b"",
            headers={"host": endpoint_host(), "x-amz-content-sha256": SHA256_EMPTY},
        )
        SigV4Auth(aws_test_credentials(), "s3", "us-east-1").add_auth(req2)
        resp2 = requests.get(req2.url, headers=dict(req2.headers.items()), timeout=10)
        assert resp2.status_code == 200, f"got {resp2.status_code}: {resp2.text}"
        # Raw bytes — the space and slash are emitted as-is (XML escapes only
        # apply to <, >, &; space and / pass through unchanged).
        assert "<Prefix>foo bar/</Prefix>" in resp2.text, \
            f"prefix unexpectedly encoded without ?encoding-type=url; body: {resp2.text}"
    finally:
        empty_bucket(s3, bucket)
        best_effort_delete_bucket(s3, bucket)
