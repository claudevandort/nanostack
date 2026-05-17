// JS CopyObject conformance — smoke level (the modern SDK).

import { describe, it, expect } from "vitest";
import {
  S3Client,
  CreateBucketCommand,
  DeleteBucketCommand,
  PutObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  DeleteObjectCommand,
  CopyObjectCommand,
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

async function bodyToBuffer(stream: any): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of stream as AsyncIterable<Uint8Array>) {
    chunks.push(Buffer.from(chunk));
  }
  return Buffer.concat(chunks);
}

describe("CopyObject", () => {
  it("happy path: copies body within the same bucket", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-cp");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await c.send(new PutObjectCommand({
        Bucket: bucket,
        Key: "src",
        Body: Buffer.from("hello copy"),
      }));
      const out = await c.send(new CopyObjectCommand({
        Bucket: bucket,
        Key: "dst",
        CopySource: `${bucket}/src`,
      }));
      expect(out.CopyObjectResult?.ETag).toBeTruthy();

      const got = await c.send(new GetObjectCommand({ Bucket: bucket, Key: "dst" }));
      const buf = await bodyToBuffer(got.Body);
      expect(buf.toString()).toBe("hello copy");
    } finally {
      await cleanup(c, bucket, ["src", "dst"]);
    }
  });

  it("REPLACE directive overrides content-type + metadata", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-cp-rep");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await c.send(new PutObjectCommand({
        Bucket: bucket,
        Key: "src",
        Body: Buffer.from("x"),
        ContentType: "text/plain",
        Metadata: { old: "yes" },
      }));
      await c.send(new CopyObjectCommand({
        Bucket: bucket,
        Key: "dst",
        CopySource: `${bucket}/src`,
        MetadataDirective: "REPLACE",
        ContentType: "application/json",
        Metadata: { new: "ok" },
      }));
      const head = await c.send(new HeadObjectCommand({ Bucket: bucket, Key: "dst" }));
      expect(head.ContentType).toBe("application/json");
      expect(head.Metadata?.old).toBeUndefined();
      expect(head.Metadata?.new).toBe("ok");
    } finally {
      await cleanup(c, bucket, ["src", "dst"]);
    }
  });
});
