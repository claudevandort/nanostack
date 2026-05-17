// DynamoDB TTL conformance — JS suite (v0.2.3).
// Validates that @aws-sdk/client-dynamodb's UpdateTimeToLive +
// DescribeTimeToLive talk to nanostack end-to-end. Eviction is exercised
// in the Python suite (which controls the sweep interval); JS sticks to
// the wire surface so the test stays fast.

import { describe, it, expect } from "vitest";
import {
  DynamoDBClient,
  CreateTableCommand,
  DeleteTableCommand,
  UpdateTimeToLiveCommand,
  DescribeTimeToLiveCommand,
} from "@aws-sdk/client-dynamodb";

const endpoint = process.env.NANOSTACK_ENDPOINT ?? "http://127.0.0.1:4577";

function newDdb(): DynamoDBClient {
  return new DynamoDBClient({
    endpoint,
    region: "us-east-1",
    credentials: { accessKeyId: "test", secretAccessKey: "test" },
  });
}

function uniqueTable(prefix: string): string {
  return `${prefix}-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
}

async function createTable(c: DynamoDBClient, name: string): Promise<void> {
  await c.send(
    new CreateTableCommand({
      TableName: name,
      KeySchema: [{ AttributeName: "id", KeyType: "HASH" }],
      AttributeDefinitions: [{ AttributeName: "id", AttributeType: "S" }],
      BillingMode: "PAY_PER_REQUEST",
    }),
  );
}

describe("ddb-ttl (js)", () => {
  const c = newDdb();

  it("DescribeTimeToLive on never-configured table → DISABLED", async () => {
    const t = uniqueTable("js-ttl");
    await createTable(c, t);
    try {
      const desc = await c.send(new DescribeTimeToLiveCommand({ TableName: t }));
      expect(desc.TimeToLiveDescription?.TimeToLiveStatus).toBe("DISABLED");
      expect(desc.TimeToLiveDescription?.AttributeName).toBeUndefined();
    } finally {
      await c.send(new DeleteTableCommand({ TableName: t }));
    }
  });

  it("UpdateTimeToLive enable + describe round-trip", async () => {
    const t = uniqueTable("js-ttl");
    await createTable(c, t);
    try {
      const update = await c.send(
        new UpdateTimeToLiveCommand({
          TableName: t,
          TimeToLiveSpecification: { Enabled: true, AttributeName: "expires_at" },
        }),
      );
      // AWS-real: UpdateTimeToLive wraps as TimeToLiveSpecification (Enabled + AttributeName)
      expect(update.TimeToLiveSpecification?.Enabled).toBe(true);
      expect(update.TimeToLiveSpecification?.AttributeName).toBe("expires_at");

      const desc = await c.send(new DescribeTimeToLiveCommand({ TableName: t }));
      // DescribeTimeToLive wraps as TimeToLiveDescription (TimeToLiveStatus + AttributeName)
      expect(desc.TimeToLiveDescription?.TimeToLiveStatus).toBe("ENABLED");
      expect(desc.TimeToLiveDescription?.AttributeName).toBe("expires_at");
    } finally {
      await c.send(new DeleteTableCommand({ TableName: t }));
    }
  });

  it("UpdateTimeToLive disable after enable", async () => {
    const t = uniqueTable("js-ttl");
    await createTable(c, t);
    try {
      await c.send(
        new UpdateTimeToLiveCommand({
          TableName: t,
          TimeToLiveSpecification: { Enabled: true, AttributeName: "ttl" },
        }),
      );
      const disable = await c.send(
        new UpdateTimeToLiveCommand({
          TableName: t,
          TimeToLiveSpecification: { Enabled: false, AttributeName: "ttl" },
        }),
      );
      expect(disable.TimeToLiveSpecification?.Enabled).toBe(false);

      const desc = await c.send(new DescribeTimeToLiveCommand({ TableName: t }));
      expect(desc.TimeToLiveDescription?.TimeToLiveStatus).toBe("DISABLED");
    } finally {
      await c.send(new DeleteTableCommand({ TableName: t }));
    }
  });

  it("UpdateTimeToLive on missing table → ResourceNotFoundException", async () => {
    await expect(
      c.send(
        new UpdateTimeToLiveCommand({
          TableName: "js_nonexistent_ttl_xyz",
          TimeToLiveSpecification: { Enabled: true, AttributeName: "ttl" },
        }),
      ),
    ).rejects.toThrow(/ResourceNotFoundException|not found/i);
  });
});
