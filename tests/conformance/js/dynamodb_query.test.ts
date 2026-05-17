// DynamoDB Query + Scan conformance — JS suite (v0.2.1).

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import {
  DynamoDBClient,
  CreateTableCommand,
  DeleteTableCommand,
  PutItemCommand,
  QueryCommand,
} from "@aws-sdk/client-dynamodb";
import { marshall } from "@aws-sdk/util-dynamodb";

const endpoint = process.env.NANOSTACK_ENDPOINT ?? "http://127.0.0.1:4577";

function newClient(): DynamoDBClient {
  return new DynamoDBClient({
    endpoint,
    region: "us-east-1",
    credentials: { accessKeyId: "test", secretAccessKey: "test" },
  });
}

const TABLE = `js-ddb-q-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
const c = newClient();

beforeAll(async () => {
  await c.send(
    new CreateTableCommand({
      TableName: TABLE,
      KeySchema: [
        { AttributeName: "pk", KeyType: "HASH" },
        { AttributeName: "sk", KeyType: "RANGE" },
      ],
      AttributeDefinitions: [
        { AttributeName: "pk", AttributeType: "S" },
        { AttributeName: "sk", AttributeType: "N" },
      ],
      BillingMode: "PAY_PER_REQUEST",
    }),
  );
  // Seed: partition "p1" with sk 1..4, partition "p2" with sk 99.
  for (let i = 1; i <= 4; i++) {
    await c.send(
      new PutItemCommand({
        TableName: TABLE,
        Item: marshall({ pk: "p1", sk: i, kind: "view" }),
      }),
    );
  }
  await c.send(
    new PutItemCommand({
      TableName: TABLE,
      Item: marshall({ pk: "p2", sk: 99, kind: "click" }),
    }),
  );
});

afterAll(async () => {
  try {
    await c.send(new DeleteTableCommand({ TableName: TABLE }));
  } catch {
    /* best-effort */
  }
});

describe("DynamoDB Query", () => {
  it("PK only returns all items in the partition", async () => {
    const out = await c.send(
      new QueryCommand({
        TableName: TABLE,
        KeyConditionExpression: "pk = :p",
        ExpressionAttributeValues: marshall({ ":p": "p1" }),
      }),
    );
    expect(out.Count).toBe(4);
  });

  it("PK + sort-key BETWEEN filters correctly", async () => {
    const out = await c.send(
      new QueryCommand({
        TableName: TABLE,
        KeyConditionExpression: "pk = :p AND sk BETWEEN :lo AND :hi",
        ExpressionAttributeValues: marshall({ ":p": "p1", ":lo": 2, ":hi": 3 }),
      }),
    );
    expect(out.Count).toBe(2);
  });

  it("FilterExpression runs after the key match", async () => {
    const out = await c.send(
      new QueryCommand({
        TableName: TABLE,
        KeyConditionExpression: "pk = :p",
        FilterExpression: "kind = :k",
        ExpressionAttributeValues: marshall({ ":p": "p1", ":k": "view" }),
      }),
    );
    expect(out.Count).toBe(4);
  });

  it("Limit + LastEvaluatedKey support pagination", async () => {
    const first = await c.send(
      new QueryCommand({
        TableName: TABLE,
        KeyConditionExpression: "pk = :p",
        ExpressionAttributeValues: marshall({ ":p": "p1" }),
        Limit: 2,
      }),
    );
    expect(first.Count).toBe(2);
    expect(first.LastEvaluatedKey).toBeDefined();

    const second = await c.send(
      new QueryCommand({
        TableName: TABLE,
        KeyConditionExpression: "pk = :p",
        ExpressionAttributeValues: marshall({ ":p": "p1" }),
        Limit: 2,
        ExclusiveStartKey: first.LastEvaluatedKey,
      }),
    );
    expect(second.Count).toBe(2);
  });
});
