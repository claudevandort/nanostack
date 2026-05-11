// JS object-op conformance — mirrors the Go suite at smoke level.

import { describe, it, expect } from "vitest";
import {
  S3Client,
  CreateBucketCommand,
  DeleteBucketCommand,
  PutObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  DeleteObjectCommand,
  DeleteObjectsCommand,
} from "@aws-sdk/client-s3";

const endpoint = process.env.NANOSTACK_ENDPOINT ?? "http://127.0.0.1:4577";

function newClient(): S3Client {
  return new S3Client({
    endpoint,
    region: "us-east-1",
    credentials: { accessKeyId: "test", secretAccessKey: "test" },
    forcePathStyle: true,
  });
}

function uniqueBucket(prefix: string): string {
  return `${prefix}-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
}

async function bodyToBuffer(stream: any): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const c of stream) chunks.push(Buffer.from(c));
  return Buffer.concat(chunks);
}

async function safeCleanup(c: S3Client, bucket: string, keys: string[]) {
  for (const k of keys) {
    try {
      await c.send(new DeleteObjectCommand({ Bucket: bucket, Key: k }));
    } catch {}
  }
  try {
    await c.send(new DeleteBucketCommand({ Bucket: bucket }));
  } catch {}
}

describe("object operations", () => {
  it("PutObject round-trips through GetObject", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-obj");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      const body = Buffer.from("hello world from JS");
      await c.send(
        new PutObjectCommand({
          Bucket: bucket,
          Key: "k",
          Body: body,
          ContentType: "text/plain",
        }),
      );
      const got = await c.send(new GetObjectCommand({ Bucket: bucket, Key: "k" }));
      const buf = await bodyToBuffer(got.Body);
      expect(buf.equals(body)).toBe(true);
      expect(got.ContentType).toBe("text/plain");
      expect(got.AcceptRanges).toBe("bytes");
    } finally {
      await safeCleanup(c, bucket, ["k"]);
    }
  });

  it("Range request returns 206 + Content-Range", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-rng");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await c.send(
        new PutObjectCommand({
          Bucket: bucket,
          Key: "k",
          Body: Buffer.from("0123456789abcdef"),
        }),
      );
      const got = await c.send(
        new GetObjectCommand({
          Bucket: bucket,
          Key: "k",
          Range: "bytes=0-4",
        }),
      );
      const buf = await bodyToBuffer(got.Body);
      expect(buf.toString()).toBe("01234");
      expect(got.ContentRange).toBe("bytes 0-4/16");
    } finally {
      await safeCleanup(c, bucket, ["k"]);
    }
  });

  it("HeadObject returns Content-Length matching the would-be body", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-hobj");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      const body = Buffer.alloc(100, "X");
      await c.send(
        new PutObjectCommand({ Bucket: bucket, Key: "k", Body: body }),
      );
      const head = await c.send(
        new HeadObjectCommand({ Bucket: bucket, Key: "k" }),
      );
      expect(head.ContentLength).toBe(100);
      expect(head.AcceptRanges).toBe("bytes");
      expect(head.ETag).toBeTruthy();
    } finally {
      await safeCleanup(c, bucket, ["k"]);
    }
  });

  it("DeleteObject is idempotent", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-del");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await c.send(
        new DeleteObjectCommand({ Bucket: bucket, Key: "never-existed" }),
      );
    } finally {
      await safeCleanup(c, bucket, []);
    }
  });

  it("DeleteObjects batch deletes existing + missing keys", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-batch");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await c.send(
        new PutObjectCommand({ Bucket: bucket, Key: "a", Body: Buffer.from("v") }),
      );
      await c.send(
        new PutObjectCommand({ Bucket: bucket, Key: "b", Body: Buffer.from("v") }),
      );
      const out = await c.send(
        new DeleteObjectsCommand({
          Bucket: bucket,
          Delete: {
            Objects: [
              { Key: "a" },
              { Key: "b" },
              { Key: "missing" },
            ],
          },
        }),
      );
      expect(out.Deleted?.length ?? 0).toBe(3);
      expect(out.Errors?.length ?? 0).toBe(0);
    } finally {
      await safeCleanup(c, bucket, []);
    }
  });

  it("GetObject on missing key → 404 NoSuchKey", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-nokey");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await expect(
        c.send(new GetObjectCommand({ Bucket: bucket, Key: "nope" })),
      ).rejects.toMatchObject({
        name: "NoSuchKey",
        $metadata: { httpStatusCode: 404 },
      });
    } finally {
      await safeCleanup(c, bucket, []);
    }
  });
});
