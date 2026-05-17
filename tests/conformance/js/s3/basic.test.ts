// JS conformance suite: drives nanostack with the official @aws-sdk/client-s3.
// The Go suite exercises the same surface; this suite proves the wire format
// also satisfies the JS SDK's expectations.

import { describe, it, expect } from "vitest";
import {
  S3Client,
  CreateBucketCommand,
  DeleteBucketCommand,
  HeadBucketCommand,
  ListBucketsCommand,
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

async function safeDelete(client: S3Client, bucket: string) {
  try {
    await client.send(new DeleteBucketCommand({ Bucket: bucket }));
  } catch {
    /* best-effort cleanup */
  }
}

describe("CreateBucket", () => {
  it("happy path returns 200 with Location", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-cb");
    try {
      const out = await c.send(new CreateBucketCommand({ Bucket: bucket }));
      expect(out.Location).toBeTruthy();
    } finally {
      await safeDelete(c, bucket);
    }
  });

  it("duplicate returns BucketAlreadyOwnedByYou (409)", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-cb-dup");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await expect(
        c.send(new CreateBucketCommand({ Bucket: bucket })),
      ).rejects.toMatchObject({
        name: "BucketAlreadyOwnedByYou",
        $metadata: { httpStatusCode: 409 },
      });
    } finally {
      await safeDelete(c, bucket);
    }
  });
});

describe("HeadBucket", () => {
  it("existing bucket returns 200", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-hb");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      const out = await c.send(new HeadBucketCommand({ Bucket: bucket }));
      expect(out.$metadata.httpStatusCode).toBe(200);
    } finally {
      await safeDelete(c, bucket);
    }
  });

  it("missing bucket returns 404", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-hb-miss");
    await expect(
      c.send(new HeadBucketCommand({ Bucket: bucket })),
    ).rejects.toMatchObject({
      $metadata: { httpStatusCode: 404 },
    });
  });
});

describe("DeleteBucket", () => {
  it("happy path returns 204", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-db");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    const out = await c.send(new DeleteBucketCommand({ Bucket: bucket }));
    expect(out.$metadata.httpStatusCode).toBe(204);
  });

  it("missing bucket returns NoSuchBucket (404)", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-db-miss");
    await expect(
      c.send(new DeleteBucketCommand({ Bucket: bucket })),
    ).rejects.toMatchObject({
      name: "NoSuchBucket",
      $metadata: { httpStatusCode: 404 },
    });
  });
});

describe("ListBuckets", () => {
  it("returns the freshly created bucket", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-lb");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      const out = await c.send(new ListBucketsCommand({}));
      expect(out.Buckets).toBeTruthy();
      const names = (out.Buckets ?? []).map((b) => b.Name);
      expect(names).toContain(bucket);
      expect(out.Owner?.ID).toBeTruthy();
    } finally {
      await safeDelete(c, bucket);
    }
  });
});
