// DynamoDB PartiQL conformance — JS suite (v0.2.4).
// Validates that @aws-sdk/client-dynamodb's ExecuteStatement /
// ExecuteTransaction / BatchExecuteStatement talk to nanostack
// end-to-end.

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import {
  DynamoDBClient,
  CreateTableCommand,
  DeleteTableCommand,
  PutItemCommand,
  ExecuteStatementCommand,
  ExecuteTransactionCommand,
  BatchExecuteStatementCommand,
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
  return `${prefix}_${Date.now()}_${Math.floor(Math.random() * 1e6)}`;
}

describe("ddb-partiql (js)", () => {
  const c = newDdb();
  const T = uniqueTable("js_ptq");

  beforeAll(async () => {
    await c.send(
      new CreateTableCommand({
        TableName: T,
        KeySchema: [{ AttributeName: "id", KeyType: "HASH" }],
        AttributeDefinitions: [{ AttributeName: "id", AttributeType: "S" }],
        BillingMode: "PAY_PER_REQUEST",
      }),
    );
  });
  afterAll(async () => {
    await c.send(new DeleteTableCommand({ TableName: T }));
  });

  it("ExecuteStatement: SELECT * scan", async () => {
    await c.send(new PutItemCommand({ TableName: T, Item: { id: { S: "scan1" } } }));
    const out = await c.send(new ExecuteStatementCommand({ Statement: `SELECT * FROM "${T}"` }));
    const ids = (out.Items ?? []).map((it) => it.id?.S);
    expect(ids).toContain("scan1");
  });

  it("ExecuteStatement: INSERT + parameterised SELECT", async () => {
    await c.send(
      new ExecuteStatementCommand({
        Statement: `INSERT INTO "${T}" VALUE {'id': ?, 'v': ?}`,
        Parameters: [{ S: "js_ins" }, { N: "42" }],
      }),
    );
    const out = await c.send(
      new ExecuteStatementCommand({
        Statement: `SELECT * FROM "${T}" WHERE id = ?`,
        Parameters: [{ S: "js_ins" }],
      }),
    );
    expect(out.Items?.length).toBe(1);
    expect(out.Items![0].v?.N).toBe("42");
  });

  it("ExecuteStatement: UPDATE SET + atomic counter", async () => {
    await c.send(
      new PutItemCommand({ TableName: T, Item: { id: { S: "js_upd" }, ctr: { N: "10" } } }),
    );
    await c.send(
      new ExecuteStatementCommand({
        Statement: `UPDATE "${T}" SET ctr = ctr + ? WHERE id = ?`,
        Parameters: [{ N: "5" }, { S: "js_upd" }],
      }),
    );
    const out = await c.send(
      new ExecuteStatementCommand({
        Statement: `SELECT ctr FROM "${T}" WHERE id = ?`,
        Parameters: [{ S: "js_upd" }],
      }),
    );
    expect(["15", "15.0"]).toContain(out.Items![0].ctr?.N);
  });

  it("ExecuteStatement: DELETE", async () => {
    await c.send(new PutItemCommand({ TableName: T, Item: { id: { S: "js_del" } } }));
    await c.send(
      new ExecuteStatementCommand({
        Statement: `DELETE FROM "${T}" WHERE id = ?`,
        Parameters: [{ S: "js_del" }],
      }),
    );
    const out = await c.send(
      new ExecuteStatementCommand({
        Statement: `SELECT * FROM "${T}" WHERE id = ?`,
        Parameters: [{ S: "js_del" }],
      }),
    );
    expect(out.Items).toEqual([]);
  });

  it("ExecuteTransaction: atomic inserts", async () => {
    await c.send(
      new ExecuteTransactionCommand({
        TransactStatements: [
          { Statement: `INSERT INTO "${T}" VALUE {'id': 'tx_a'}` },
          { Statement: `INSERT INTO "${T}" VALUE {'id': 'tx_b'}` },
        ],
      }),
    );
    const out = await c.send(
      new ExecuteStatementCommand({
        Statement: `SELECT * FROM "${T}" WHERE id = ?`,
        Parameters: [{ S: "tx_a" }],
      }),
    );
    expect(out.Items?.length).toBe(1);
  });

  it("BatchExecuteStatement: mixed ops with per-statement Responses", async () => {
    await c.send(new PutItemCommand({ TableName: T, Item: { id: { S: "batch_pre" } } }));
    const out = await c.send(
      new BatchExecuteStatementCommand({
        Statements: [
          { Statement: `INSERT INTO "${T}" VALUE {'id': 'batch_new'}` },
          { Statement: `SELECT * FROM "${T}" WHERE id = ?`, Parameters: [{ S: "batch_pre" }] },
        ],
      }),
    );
    expect(out.Responses?.length).toBe(2);
    expect(out.Responses![1].Item?.id?.S).toBe("batch_pre");
  });
});
