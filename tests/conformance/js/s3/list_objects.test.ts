// JS list-op conformance — covers ListObjectsV2 surface.

import { describe, it, expect } from "vitest";
import {
  S3Client,
  CreateBucketCommand,
  DeleteBucketCommand,
  PutObjectCommand,
  DeleteObjectCommand,
  ListObjectsV2Command,
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

async function seedKeys(c: S3Client, bucket: string, keys: string[]) {
  await c.send(new CreateBucketCommand({ Bucket: bucket }));
  for (const k of keys) {
    await c.send(
      new PutObjectCommand({ Bucket: bucket, Key: k, Body: "v" }),
    );
  }
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

describe("ListObjectsV2", () => {
  it("happy path: returns all keys in sorted order", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-lov2");
    const keys = ["alpha", "beta", "gamma"];
    await seedKeys(c, bucket, keys);
    try {
      const out = await c.send(
        new ListObjectsV2Command({ Bucket: bucket }),
      );
      expect(out.KeyCount).toBe(3);
      const got = (out.Contents ?? []).map((o) => o.Key);
      expect(got).toEqual(["alpha", "beta", "gamma"]);
    } finally {
      await cleanup(c, bucket, keys);
    }
  });

  it("prefix + delimiter returns CommonPrefixes", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-lov2d");
    const keys = ["a/1", "a/2", "b/3", "c"];
    await seedKeys(c, bucket, keys);
    try {
      const out = await c.send(
        new ListObjectsV2Command({ Bucket: bucket, Delimiter: "/" }),
      );
      expect((out.Contents ?? []).map((o) => o.Key)).toEqual(["c"]);
      const cps = (out.CommonPrefixes ?? [])
        .map((p) => p.Prefix)
        .sort();
      expect(cps).toEqual(["a/", "b/"]);
    } finally {
      await cleanup(c, bucket, keys);
    }
  });

  it("pagination via continuation-token", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-lov2p");
    const keys = ["k1", "k2", "k3", "k4", "k5"];
    await seedKeys(c, bucket, keys);
    try {
      const seen: string[] = [];
      let token: string | undefined = undefined;
      let pages = 0;
      while (true) {
        pages++;
        const out: any = await c.send(
          new ListObjectsV2Command({
            Bucket: bucket,
            MaxKeys: 2,
            ContinuationToken: token,
          }),
        );
        for (const o of out.Contents ?? []) seen.push(o.Key);
        if (!out.IsTruncated) break;
        token = out.NextContinuationToken;
        if (pages > 10) throw new Error("too many pages");
      }
      expect(pages).toBe(3);
      seen.sort();
      expect(seen).toEqual(keys);
    } finally {
      await cleanup(c, bucket, keys);
    }
  });
});
