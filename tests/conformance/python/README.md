# nanostack — Python (boto3) Conformance Suite

Drives the official AWS Python SDK (boto3) against a running nanostack and
asserts AWS-compatible responses.

## Setup

```sh
cd tests/conformance/python
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Run

Start a nanostack on a dedicated port, then run pytest against it:

```sh
# In one shell:
../../../zig-out/bin/nanostack --port 14566 --data-dir "$(mktemp -d)"

# In another (with the venv active):
NANOSTACK_ENDPOINT=http://127.0.0.1:14566 pytest -v
```

To run a single test file:

```sh
NANOSTACK_ENDPOINT=http://127.0.0.1:14566 pytest -v test_create_bucket.py
```

To run in parallel (faster for the full suite):

```sh
NANOSTACK_ENDPOINT=http://127.0.0.1:14566 pytest -n auto
```

## Layout

- `conftest.py` — shared fixtures (`s3` client, `bucket_name`) and
  helpers (`unique_bucket`, `best_effort_delete_bucket`, `drain_versions`,
  `empty_bucket`, `seed_object`, `make_payload`, `aws_error_code`,
  `aws_http_status`, `MIN_PART_SIZE`).
- `test_*.py` — one file per S3 op group (mirrors the Smithy-op grouping
  in `src/services/s3/`).

## Conventions

- Every test uses the `bucket_name` fixture for a unique name derived from
  the test function. Cleanup is each test's responsibility (use
  `best_effort_delete_bucket` in a try/finally, or use
  `empty_bucket(...)` + `best_effort_delete_bucket` for versioned/locked
  buckets).
- Error assertions use `botocore.exceptions.ClientError` and the
  `aws_error_code` / `aws_http_status` helpers.
- For ops the SDK doesn't expose (e.g. 2025-vintage UpdateObjectEncryption),
  hand-sign with `botocore.auth.SigV4Auth` and send via `requests` /
  `urllib3` — see `test_update_encryption.py` as the canonical example.
