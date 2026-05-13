# nanostack

A snappy, accurate AWS emulator for local development, written in Zig.

**Status:** `v0.0.1` — first pinned cut of the S3 v1 surface. Pre-`v1.0.0`; expect minor breaking changes between tags. See [`CHANGELOG.md`](CHANGELOG.md) for the versioning scheme.

## What it is

- **Single static binary** — no Docker, no JVM, no Python. ~0.8 MB stripped.
- **Sub-second cold start, ~11 MB idle RSS** — designed for tight test loops and CI.
- **Accurate on the surface it covers** — every supported AWS operation has a conformance test that runs the official AWS Go + JS SDKs against it. See [`SCORECARD.md`](SCORECARD.md) for the four documented points where nanostack matches AWS and LocalStack does not.
- **S3 first.** 19 S3 operations: bucket lifecycle, object CRUD, copy, listing, full multipart, all the conditional headers. More services follow once the foundation is proven.

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

- `nanostack-v0.0.1-linux-x86_64.tar.gz`
- `nanostack-v0.0.1-linux-aarch64.tar.gz`
- `nanostack-v0.0.1-macos-x86_64.tar.gz`
- `nanostack-v0.0.1-macos-aarch64.tar.gz`

Verify with the published `SHA256SUMS`, then extract:

```sh
tar -xzf nanostack-v0.0.1-linux-x86_64.tar.gz
./nanostack --version
```

> macOS binaries are unsigned at v0.0.1. Gatekeeper will warn on first launch; right-click → Open, or `xattr -d com.apple.quarantine ./nanostack`. Apple Developer ID notarisation is planned for the next patch.

### Build from source

Requires **Zig 0.16.0**.

```sh
git clone https://github.com/claudevandort/nanostack
cd nanostack
zig build
./zig-out/bin/nanostack --version   # → nanostack v0.0.1
```

## Quickstart

```sh
# Run with a temporary data dir (auto-cleaned on exit).
nanostack --port 4566 --data-dir "$(mktemp -d)" &

# Then point any AWS SDK at it.
aws --endpoint-url http://127.0.0.1:4566 s3 mb s3://my-bucket
aws --endpoint-url http://127.0.0.1:4566 s3 cp ./README.md s3://my-bucket/
aws --endpoint-url http://127.0.0.1:4566 s3 ls s3://my-bucket
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

See [`SCORECARD.md`](SCORECARD.md) for the four LocalStack regression cases we explicitly fix.

## Docs

- [`SUPPORT.md`](SUPPORT.md) — live operation status matrix.
- [`SCORECARD.md`](SCORECARD.md) — where nanostack beats LocalStack on accuracy.
- [`BENCH.md`](BENCH.md) — perf budgets + current numbers.
- [`CHANGELOG.md`](CHANGELOG.md) — release notes + versioning scheme.
- [`docs/PRD.md`](docs/PRD.md) — full product spec and design decisions.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
