# syntax=docker/dockerfile:1
#
# Multi-arch nanostack image, ~1.5 MB. The musl-static binary is cross-
# compiled outside Docker (via `zig build release -Dtarget=...-linux-musl`)
# and dropped into the build context as `nanostack-amd64` / `nanostack-arm64`
# before `docker buildx build --platform linux/amd64,linux/arm64` runs.
# `ARG TARGETARCH` is set automatically by buildx for each platform.

FROM scratch

ARG TARGETARCH
COPY nanostack-${TARGETARCH} /nanostack

# Default S3 port. Override at runtime with `-p <host>:4566` and
# `--port 4566` (the default ENTRYPOINT/CMD targets the same).
EXPOSE 4566

# Mount a volume on /data to persist buckets across container restarts;
# omit the mount for a wipe-clean run (the container will use its own
# ephemeral filesystem).
VOLUME ["/data"]

ENTRYPOINT ["/nanostack"]
CMD ["--port", "4566", "--data-dir", "/data"]
