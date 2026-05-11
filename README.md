# nanostack

A snappy, accurate AWS emulator for local development, written in Zig.

**Status:** pre-alpha. M0 (skeleton) in progress. See [`docs/PRD.md`](docs/PRD.md) for the full product spec.

## What it is

- **Single static binary** — no Docker, no JVM, no Python.
- **Sub-second cold start, low idle memory** — designed for tight test loops and CI.
- **Accurate on the surface it covers** — every supported AWS operation has a conformance test that runs the official AWS SDKs against it.
- **Curated service set** — S3 first. More services land only after the foundation is proven.

## What it is not

- Not a production-grade S3-compatible storage system. Use [MinIO](https://github.com/minio/minio) for that.
- Not full LocalStack parity. We deliberately pick a smaller, sharper surface and make it accurate.

## Build

Requires **Zig 0.16.0**.

```sh
zig build              # builds ./zig-out/bin/nanostack
zig build test         # runs unit tests
./zig-out/bin/nanostack
# listening on http://127.0.0.1:4566
```

## Conformance

```sh
cd tests/conformance/go
go test ./...
```

The conformance suite runs the official AWS SDK against a running nanostack. It is the artefact that proves the "accurate" claim. See [`SUPPORT.md`](SUPPORT.md) for the live operation status matrix.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
