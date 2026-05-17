// DynamoDB transactional conformance — JS suite (v0.2.1).

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import {
  DynamoDBClient,
  CreateTableCommand,
  DeleteTableCommand,
  PutItemCommand,
  GetItemCommand,
  TransactWriteItemsCommand,
} from "@aws-sdk/client-dynamodb";
import { marshall, unmarshall } from "@aws-sdk/util-dynamodb";

const endpoint = process.env.NANOSTACK_ENDPOINT ?? "http://127.0.0.1:4577";

function newClient(): DynamoDBClient {
  return new DynamoDBClient({
    endpoint,
    region: "us-east-1",
    credentials: { accessKeyId: "test", secretAccessKey: "test" },
  });
}

const TABLE = `js-ddb-tx-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
const c = newClient();

beforeAll(async () => {
  await c.send(
    new CreateTableCommand({
      TableName: TABLE,
      KeySchema: [{ AttributeName: "id", KeyType: "HASH" }],
      AttributeDefinitions: [{ AttributeName: "id", AttributeType: "S" }],
      BillingMode: "PAY_PER_REQUEST",
    }),
  );
  await c.send(
    new PutItemCommand({ TableName: TABLE, Item: marshall({ id: "alice", balance: 100 }) }),
  );
  await c.send(
    new PutItemCommand({ TableName: TABLE, Item: marshall({ id: "bob", balance: 50 }) }),
  );
});

afterAll(async () => {
  try {
    await c.send(new DeleteTableCommand({ TableName: TABLE }));
  } catch {
    /* best-effort */
  }
});

describe("DynamoDB TransactWriteItems", () => {
  it("atomic transfer commits both updates", async () => {
    await c.send(
      new TransactWriteItemsCommand({
        TransactItems: [
          {
            Update: {
              TableName: TABLE,
              Key: marshall({ id: "alice" }),
              UpdateExpression: "SET balance = balance - :n",
              ExpressionAttributeValues: marshall({ ":n": 10 }),
            },
          },
          {
            Update: {
              TableName: TABLE,
              Key: marshall({ id: "bob" }),
              UpdateExpression: "SET balance = balance + :n",
              ExpressionAttributeValues: marshall({ ":n": 10 }),
            },
          },
        ],
      }),
    );
    const alice = await c.send(
      new GetItemCommand({ TableName: TABLE, Key: marshall({ id: "alice" }) }),
    );
    const bob = await c.send(
      new GetItemCommand({ TableName: TABLE, Key: marshall({ id: "bob" }) }),
    );
    expect(unmarshall(alice.Item!).balance).toBe(90);
    expect(unmarshall(bob.Item!).balance).toBe(60);
  });

  it("failing ConditionExpression cancels the whole transaction", async () => {
    await expect(
      c.send(
        new TransactWriteItemsCommand({
          TransactItems: [
            {
              Put: {
                TableName: TABLE,
                Item: marshall({ id: "new-ghost", balance: 1 }),
                ConditionExpression: "attribute_not_exists(id)",
              },
            },
            {
              Put: {
                TableName: TABLE,
                // alice already exists → fails attribute_not_exists.
                Item: marshall({ id: "alice", balance: 999 }),
                ConditionExpression: "attribute_not_exists(id)",
              },
            },
          ],
        }),
      ),
    ).rejects.toMatchObject({ name: "TransactionCanceledException" });

    // The ghost row must NOT have landed.
    const ghost = await c.send(
      new GetItemCommand({ TableName: TABLE, Key: marshall({ id: "new-ghost" }) }),
    );
    expect(ghost.Item).toBeUndefined();
  });
});
