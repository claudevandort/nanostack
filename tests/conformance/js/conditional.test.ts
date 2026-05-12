// JS conditional-request conformance — smokes for 304 (GET) and 412 (PUT).

import { describe, it, expect } from "vitest";
import {
  S3Client,
  CreateBucketCommand,
  DeleteBucketCommand,
  PutObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  DeleteObjectCommand,
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

async function cleanup(c: S3Client, bucket: string, keys: string[]) {
  for (const k of keys) {
    try {
      await c.send(new DeleteObjectCommand({ Bucket: bucket, Key: k }));
    } catch {
      /* best-effort */
    }
  }
  try {
    await c.send(new DeleteBucketCommand({ Bucket: bucket }));
  } catch {
    /* best-effort */
  }
}

describe("conditional requests", () => {
  it("GET with IfNoneMatch matching returns 304", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-cg-inm");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await c.send(new PutObjectCommand({
        Bucket: bucket,
        Key: "k",
        Body: Buffer.from("x"),
      }));
      const head = await c.send(new HeadObjectCommand({ Bucket: bucket, Key: "k" }));
      const etag = head.ETag!;

      await expect(
        c.send(new GetObjectCommand({
          Bucket: bucket,
          Key: "k",
          IfNoneMatch: etag,
        })),
      ).rejects.toMatchObject({
        $metadata: { httpStatusCode: 304 },
      });
    } finally {
      await cleanup(c, bucket, ["k"]);
    }
  });

  it("GET with IfMatch mismatch returns 412", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-cg-ifm");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await c.send(new PutObjectCommand({
        Bucket: bucket,
        Key: "k",
        Body: Buffer.from("x"),
      }));
      await expect(
        c.send(new GetObjectCommand({
          Bucket: bucket,
          Key: "k",
          IfMatch: `"deadbeef"`,
        })),
      ).rejects.toMatchObject({
        name: "PreconditionFailed",
        $metadata: { httpStatusCode: 412 },
      });
    } finally {
      await cleanup(c, bucket, ["k"]);
    }
  });

  it("PUT IfNoneMatch=* against existing returns 412", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-cp-inm");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await c.send(new PutObjectCommand({
        Bucket: bucket,
        Key: "k",
        Body: Buffer.from("orig"),
      }));
      await expect(
        c.send(new PutObjectCommand({
          Bucket: bucket,
          Key: "k",
          Body: Buffer.from("new"),
          IfNoneMatch: "*",
        })),
      ).rejects.toMatchObject({
        name: "PreconditionFailed",
        $metadata: { httpStatusCode: 412 },
      });
    } finally {
      await cleanup(c, bucket, ["k"]);
    }
  });
});
