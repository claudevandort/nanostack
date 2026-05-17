"""`aws s3 presign` conformance.

The CLI's `presign` subcommand generates a SigV4-presigned URL with the
caller's credentials. Any unauthenticated client (including `urllib`) can
then fetch the object. This test verifies:

1. The CLI generates a URL pointed at our endpoint with the right path.
2. The URL authenticates successfully when fetched.
3. The response body matches the original object.
"""

from pathlib import Path
from urllib.request import urlopen
from urllib.parse import urlparse

from conftest import endpoint, run_aws


def test_presign_generates_url_that_resolves(bucket: str, tmp_path: Path):
    payload = b"presigned-content\nwith a newline\n"
    src = tmp_path / "src.txt"
    src.write_bytes(payload)
    run_aws("s3", "cp", str(src), f"s3://{bucket}/k")

    # Generate a presigned URL valid for 60 seconds.
    presigned = run_aws("s3", "presign", f"s3://{bucket}/k", "--expires-in", "60").stdout.strip()
    assert presigned.startswith(endpoint()), \
        f"presigned URL should target our endpoint; got: {presigned!r}"
    # SigV4 query params should be present.
    parsed = urlparse(presigned)
    assert "X-Amz-Signature=" in parsed.query, \
        f"missing SigV4 signature on presigned URL: {presigned!r}"

    # Fetch the URL anonymously — signature alone must authenticate.
    with urlopen(presigned, timeout=10) as resp:
        assert resp.status == 200, f"presigned fetch returned {resp.status}"
        body = resp.read()
    assert body == payload, "presigned fetch returned wrong body"
