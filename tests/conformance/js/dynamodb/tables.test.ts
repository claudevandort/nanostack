// DynamoDB table-management conformance — JS suite (v0.2.1).
//
// Proves the wire format works with @aws-sdk/client-dynamodb v3.

import { describe, it, expect } from "vitest";
import {
  DynamoDBClient,
  CreateTableCommand,
  DescribeTableCommand,
  ListTablesCommand,
  DeleteTableCommand,
} from "@aws-sdk/client-dynamodb";

const endpoint = process.env.NANOSTACK_ENDPOINT ?? "http://127.0.0.1:4577";

function newClient(): DynamoDBClient {
  return new DynamoDBClient({
    endpoint,
    region: "us-east-1",
    credentials: { accessKeyId: "test", secretAccessKey: "test" },
  });
}

function uniqueName(prefix: string): string {
  return `${prefix}-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
}

async function safeDelete(client: DynamoDBClient, name: string) {
  try {
    await client.send(new DeleteTableCommand({ TableName: name }));
  } catch {
    /* best-effort */
  }
}

describe("DynamoDB CreateTable / DescribeTable", () => {
  it("HASH-only key round-trips", async () => {
    const c = newClient();
    const name = uniqueName("js-ddb-tbl");
    try {
      const create = await c.send(
        new CreateTableCommand({
          TableName: name,
          KeySchema: [{ AttributeName: "id", KeyType: "HASH" }],
          AttributeDefinitions: [{ AttributeName: "id", AttributeType: "S" }],
          BillingMode: "PAY_PER_REQUEST",
        }),
      );
      expect(create.TableDescription?.TableName).toBe(name);
      expect(create.TableDescription?.TableStatus).toBe("ACTIVE");

      const describe = await c.send(new DescribeTableCommand({ TableName: name }));
      expect(describe.Table?.KeySchema?.[0].AttributeName).toBe("id");
      expect(describe.Table?.KeySchema?.[0].KeyType).toBe("HASH");
    } finally {
      await safeDelete(c, name);
    }
  });

  it("composite HASH+RANGE key with GSI definition", async () => {
    const c = newClient();
    const name = uniqueName("js-ddb-gsi");
    try {
      await c.send(
        new CreateTableCommand({
          TableName: name,
          KeySchema: [
            { AttributeName: "pk", KeyType: "HASH" },
            { AttributeName: "sk", KeyType: "RANGE" },
          ],
          AttributeDefinitions: [
            { AttributeName: "pk", AttributeType: "S" },
            { AttributeName: "sk", AttributeType: "N" },
            { AttributeName: "gsi_pk", AttributeType: "S" },
          ],
          GlobalSecondaryIndexes: [
            {
              IndexName: "by-gsi",
              KeySchema: [{ AttributeName: "gsi_pk", KeyType: "HASH" }],
              Projection: { ProjectionType: "ALL" },
            },
          ],
          BillingMode: "PAY_PER_REQUEST",
        }),
      );
      const out = await c.send(new DescribeTableCommand({ TableName: name }));
      expect(out.Table?.GlobalSecondaryIndexes?.length).toBe(1);
      expect(out.Table?.GlobalSecondaryIndexes?.[0].IndexName).toBe("by-gsi");
    } finally {
      await safeDelete(c, name);
    }
  });
});

describe("DynamoDB ListTables", () => {
  it("returns an array (possibly empty)", async () => {
    const c = newClient();
    const out = await c.send(new ListTablesCommand({}));
    expect(Array.isArray(out.TableNames)).toBe(true);
  });
});

describe("DynamoDB DeleteTable", () => {
  it("removes the table; subsequent describe → ResourceNotFoundException", async () => {
    const c = newClient();
    const name = uniqueName("js-ddb-del");
    await c.send(
      new CreateTableCommand({
        TableName: name,
        KeySchema: [{ AttributeName: "id", KeyType: "HASH" }],
        AttributeDefinitions: [{ AttributeName: "id", AttributeType: "S" }],
        BillingMode: "PAY_PER_REQUEST",
      }),
    );
    await c.send(new DeleteTableCommand({ TableName: name }));
    await expect(
      c.send(new DescribeTableCommand({ TableName: name })),
    ).rejects.toMatchObject({ name: "ResourceNotFoundException" });
  });
});
