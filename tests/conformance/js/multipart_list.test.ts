// JS multipart listing — ListMultipartUploads + ListParts smokes.

import { describe, it, expect } from "vitest";
import {
  S3Client,
  CreateBucketCommand,
  DeleteBucketCommand,
  CreateMultipartUploadCommand,
  AbortMultipartUploadCommand,
  UploadPartCommand,
  ListMultipartUploadsCommand,
  ListPartsCommand,
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

describe("ListMultipartUploads + ListParts", () => {
  it("ListMultipartUploads returns active uploads", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-lmu");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    const ids: { key: string; id: string }[] = [];
    try {
      for (const key of ["alpha", "beta"]) {
        const init = await c.send(new CreateMultipartUploadCommand({ Bucket: bucket, Key: key }));
        ids.push({ key, id: init.UploadId! });
      }
      const out = await c.send(new ListMultipartUploadsCommand({ Bucket: bucket }));
      expect(out.Uploads?.length).toBe(2);
      const keys = (out.Uploads ?? []).map((u) => u.Key).sort();
      expect(keys).toEqual(["alpha", "beta"]);
    } finally {
      for (const { key, id } of ids) {
        try {
          await c.send(new AbortMultipartUploadCommand({ Bucket: bucket, Key: key, UploadId: id }));
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
  });

  it("ListParts pagination", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-lp");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    let uploadId = "";
    try {
      const init = await c.send(new CreateMultipartUploadCommand({ Bucket: bucket, Key: "k" }));
      uploadId = init.UploadId!;
      for (let i = 1; i <= 5; i++) {
        await c.send(new UploadPartCommand({
          Bucket: bucket, Key: "k", UploadId: uploadId,
          PartNumber: i, Body: Buffer.from("x"),
        }));
      }
      let pages = 0;
      let marker: string | undefined;
      const seen: number[] = [];
      while (true) {
        pages++;
        const out: any = await c.send(new ListPartsCommand({
          Bucket: bucket, Key: "k", UploadId: uploadId,
          MaxParts: 2,
          PartNumberMarker: marker,
        }));
        for (const p of out.Parts ?? []) seen.push(p.PartNumber);
        if (!out.IsTruncated) break;
        marker = out.NextPartNumberMarker;
        if (pages > 10) throw new Error("too many pages");
      }
      expect(pages).toBe(3);
      expect(seen.sort((a, b) => a - b)).toEqual([1, 2, 3, 4, 5]);
    } finally {
      if (uploadId) {
        try {
          await c.send(new AbortMultipartUploadCommand({ Bucket: bucket, Key: "k", UploadId: uploadId }));
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
  });
});
