# nanostack conformance

Three parallel suites — one per AWS SDK we exercise. Each suite is split
service-first inside, so adding a third service (SQS, etc.) is just a
new subdirectory under each client.

```
tests/conformance/
├── python/         # boto3 (Python)
│   ├── conftest.py
│   ├── pyproject.toml
│   ├── requirements.txt
│   ├── s3/         # 24 test files, ~195 tests
│   └── dynamodb/   # 9 test files, ~113 tests
├── js/             # aws-sdk-js v3 (Node + vitest)
│   ├── package.json
│   ├── s3/         # 22 test files, ~51 tests
│   └── dynamodb/   # 4 test files, ~14 tests
└── awscli/         # AWS CLI v2 (pytest driving subprocess)
    ├── conftest.py
    ├── pyproject.toml
    ├── s3/         # 4 test files, ~10 tests
    └── dynamodb/   # 3 test files, ~9 tests
```

**Test totals (v0.2.1):** 308 Python + 65 JS + 19 AWS CLI = 392 conformance tests
exercising the same nanostack instance.

## Running locally

Start nanostack with both services enabled (the CI default):

```sh
./zig-out/bin/nanostack --port 14566 --data-dir "$(mktemp -d)" --services s3,dynamodb &
export NANOSTACK_ENDPOINT=http://127.0.0.1:14566
export NANOSTACK_BIN=$(realpath ./zig-out/bin/nanostack)
```

Then run any suite — pytest and vitest auto-discover into the
service subdirs:

```sh
# Python
cd tests/conformance/python && source .venv/bin/activate && pytest -n auto

# JS
cd tests/conformance/js && npm test

# AWS CLI v2 (requires `aws --version` reporting v2.x)
cd tests/conformance/awscli && source .venv/bin/activate && pytest -n auto
```

Scope a single service:

```sh
cd tests/conformance/python && pytest -n auto s3/
cd tests/conformance/python && pytest -n auto dynamodb/
```

## Adding tests for a new service

1. Pick the client surface(s) the service ships against — typically all three.
2. Create `tests/conformance/{python,js,awscli}/<service>/` and drop tests there.
3. No conftest / pyproject / package.json changes needed at the client
   root — pytest's `pythonpath = ["."]` and vitest's default test glob
   (`**/*.test.ts`) already pick up nested dirs.
4. Document the service in [`docs/SUPPORT.md`](../../docs/SUPPORT.md) so
   it shows up in the public op matrix.
