# nanostack

A snappy, accurate AWS emulator for local development, written in Zig.

**Status:** `v0.1.0` — S3 is functionally complete for local-dev use (**68 / 107 Smithy ops routed, ~99% of real dev workflows covered**). Pre-`v1.0.0`; expect minor breaking changes between tags. See [`docs/CHANGELOG.md`](docs/CHANGELOG.md) for the versioning scheme.

## What it is

- **Single static binary** — no Docker, no JVM, no Python. ~0.8 MB stripped.
- **Sub-second cold start, ~11 MB idle RSS** — designed for tight test loops and CI.
- **Accurate on the surface it covers** — every supported AWS operation has a conformance test that runs the official AWS Go + JS SDKs against it. See [`docs/SCORECARD.md`](docs/SCORECARD.md) for the four documented points where nanostack matches AWS and LocalStack does not.
- **S3 done.** Full v1 surface (bucket lifecycle, object CRUD, copy, listing, multipart, conditional headers, SigV4 + presigned URLs) plus versioning, tagging, ACLs/policies, CORS/encryption/lifecycle/notifications/website, **Object Lock with real WORM enforcement**, restore, replication. More services follow now that the foundation is proven.

## What it is not

- Not a production-grade S3-compatible storage system. Use [MinIO](https://github.com/minio/minio) for that.
- Not full LocalStack parity. We deliberately pick a smaller, sharper surface and make it accurate.

## Install

### Homebrew (macOS, Linux)

```sh
brew tap claudevandort/nanostack
brew install nanostack
```

### Prebuilt tarball

Download from the [GitHub Releases page](https://github.com/claudevandort/nanostack/releases). Available builds:

- `nanostack-v0.1.0-linux-x86_64.tar.gz`
- `nanostack-v0.1.0-linux-aarch64.tar.gz`
- `nanostack-v0.1.0-macos-x86_64.tar.gz`
- `nanostack-v0.1.0-macos-aarch64.tar.gz`

Verify with the published `SHA256SUMS`, then extract:

```sh
tar -xzf nanostack-v0.1.0-linux-x86_64.tar.gz
./nanostack --version
```

> macOS binaries are unsigned at v0.1.0. Gatekeeper will warn on first launch; right-click → Open, or `xattr -d com.apple.quarantine ./nanostack`. Apple Developer ID notarisation is planned for the next patch.

### Build from source

Requires **Zig 0.16.0**.

```sh
git clone https://github.com/claudevandort/nanostack
cd nanostack
zig build
./zig-out/bin/nanostack --version   # → nanostack v0.1.0
```

## Quickstart

```sh
# Run with a temporary data dir (auto-cleaned on exit).
nanostack --port 4566 --data-dir "$(mktemp -d)" &

# Then point any AWS SDK at it.
aws --endpoint-url http://127.0.0.1:4566 s3 mb s3://my-bucket
aws --endpoint-url http://127.0.0.1:4566 s3 cp ./README.md s3://my-bucket/
aws --endpoint-url http://127.0.0.1:4566 s3 ls s3://my-bucket

# Compliance: create a WORM-locked bucket, lock an object, watch the delete fail.
aws --endpoint-url http://127.0.0.1:4566 s3api create-bucket --bucket vault --object-lock-enabled-for-bucket
aws --endpoint-url http://127.0.0.1:4566 s3api put-object --bucket vault --key audit.log --body audit.log \
    --object-lock-mode GOVERNANCE \
    --object-lock-retain-until-date 2099-01-01T00:00:00Z
V=$(aws --endpoint-url http://127.0.0.1:4566 s3api list-object-versions --bucket vault --query 'Versions[0].VersionId' --output text)
aws --endpoint-url http://127.0.0.1:4566 s3api delete-object --bucket vault --key audit.log --version-id "$V"
# → 403 AccessDenied (WORM-protected)
```

The default credentials are `test`/`test`; override with `--access-key` and `--secret-key`. For curl-friendly debugging, add `--no-auth` (do not use for accuracy testing — real AWS rejects unsigned requests).

## Conformance

Every supported AWS operation is asserted by the Go + JS SDK conformance suites. They run on every push.

```sh
# Run a fresh nanostack on a dedicated port, then drive both suites at it.
./zig-out/bin/nanostack --port 14566 --data-dir "$(mktemp -d)" &

cd tests/conformance/go && \
  NANOSTACK_ENDPOINT=http://127.0.0.1:14566 \
  go test -count=1 ./...

cd ../js && \
  NANOSTACK_ENDPOINT=http://127.0.0.1:14566 \
  npm test
```

See [`docs/SCORECARD.md`](docs/SCORECARD.md) for the four LocalStack regression cases we explicitly fix.

## Docs

All docs live in [`docs/`](docs/):

- [`docs/SUPPORT.md`](docs/SUPPORT.md) — live operation status matrix.
- [`docs/SCORECARD.md`](docs/SCORECARD.md) — where nanostack beats LocalStack on accuracy.
- [`docs/COVERAGE.md`](docs/COVERAGE.md) — Smithy-derived op coverage report (regenerated via `scripts/smithy_coverage.py`).
- [`docs/BENCH.md`](docs/BENCH.md) — perf budgets + current numbers.
- [`docs/CHANGELOG.md`](docs/CHANGELOG.md) — release notes + versioning scheme.
- [`docs/PRD.md`](docs/PRD.md) — full product spec and design decisions.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
