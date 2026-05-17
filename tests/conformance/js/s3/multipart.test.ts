// JS multipart conformance — happy path with the SDK Upload helper +
// manual lifecycle smoke.

import { describe, it, expect } from "vitest";
import {
  S3Client,
  CreateBucketCommand,
  DeleteBucketCommand,
  CreateMultipartUploadCommand,
  UploadPartCommand,
  CompleteMultipartUploadCommand,
  GetObjectCommand,
  DeleteObjectCommand,
} from "@aws-sdk/client-s3";
import { Upload } from "@aws-sdk/lib-storage";

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

describe("multipart upload", () => {
  it("SDK Upload helper round-trips an 8 MiB body", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-mpu");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      const body = Buffer.alloc(8 * 1024 * 1024, "A");
      const upload = new Upload({
        client: c,
        params: { Bucket: bucket, Key: "k", Body: body },
        partSize: 5 * 1024 * 1024,
      });
      const out: any = await upload.done();
      expect(out.ETag).toMatch(/-\d+"$/);

      const got = await c.send(new GetObjectCommand({ Bucket: bucket, Key: "k" }));
      const buf = await bodyToBuffer(got.Body);
      expect(buf.length).toBe(body.length);
      expect(buf.equals(body)).toBe(true);
    } finally {
      await cleanup(c, bucket, ["k"]);
    }
  });

  it("manual CreateMPU → UploadPart × 2 → CompleteMPU", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-mpu-manual");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      const init = await c.send(new CreateMultipartUploadCommand({
        Bucket: bucket,
        Key: "k",
      }));
      const uploadId = init.UploadId!;

      const part1 = Buffer.alloc(5 * 1024 * 1024, "A");
      const part2 = Buffer.from("tail");
      const p1 = await c.send(new UploadPartCommand({
        Bucket: bucket, Key: "k", UploadId: uploadId,
        PartNumber: 1, Body: part1,
      }));
      const p2 = await c.send(new UploadPartCommand({
        Bucket: bucket, Key: "k", UploadId: uploadId,
        PartNumber: 2, Body: part2,
      }));

      const cmpu = await c.send(new CompleteMultipartUploadCommand({
        Bucket: bucket, Key: "k", UploadId: uploadId,
        MultipartUpload: {
          Parts: [
            { ETag: p1.ETag, PartNumber: 1 },
            { ETag: p2.ETag, PartNumber: 2 },
          ],
        },
      }));
      expect(cmpu.ETag).toMatch(/-2"$/);
    } finally {
      await cleanup(c, bucket, ["k"]);
    }
  });
});
