# nanostack — AWS CLI Conformance Suite

Drives the real `aws` CLI v2 against a running nanostack and asserts AWS-compatible behaviour on the **high-level `aws s3` commands** (`cp`, `cp --recursive`, `sync`, `mv`, `ls`, `rm --recursive`, `presign`). These commands add client-side logic on top of botocore (recursion, diffing, composite ops) that the boto3 suite at `tests/conformance/python/` does not cover.

## Prerequisites

- **AWS CLI v2** on PATH. Verify:
  ```sh
  aws --version
  # → aws-cli/2.x.x …
  ```
  GitHub Actions ubuntu-latest and macos-latest both ship v2 pre-installed.

- Python ≥ 3.10 with pytest. (`pip install -r requirements.txt`.)

## Setup

```sh
cd tests/conformance/awscli
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

Parallel run:
```sh
NANOSTACK_ENDPOINT=http://127.0.0.1:14566 pytest -n auto
```

Single test:
```sh
NANOSTACK_ENDPOINT=http://127.0.0.1:14566 pytest -v test_s3_sync.py::test_sync_second_run_is_noop
```

## How the harness works

- `conftest.py::run_aws(*args)` wraps `subprocess.run` and appends `--endpoint-url $NANOSTACK_ENDPOINT` automatically.
- Each subprocess runs with isolated env: `AWS_ACCESS_KEY_ID=test`, `AWS_SECRET_ACCESS_KEY=test`, `AWS_DEFAULT_REGION=us-east-1`, `AWS_PAGER=""`. No `~/.aws/credentials` mutation.
- The `bucket` fixture creates a unique bucket per test and force-deletes on teardown.
