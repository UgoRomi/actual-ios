import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";

const directory = fs.mkdtempSync(path.join(os.tmpdir(), "actual-native-bank-sync-"));
const requests = [];
const date = new Date().toISOString().slice(0, 10);
let failureMode = "rate-limit";
function data(accountId) {
  const transaction = {
    transactionId: `import-${accountId}`, date, booked: true,
    payeeName: "Native Bank Merchant", notes: "Bank fixture import",
    transactionAmount: { amount: "-12.34", currency: "EUR" },
  };
  const pending = accountId === "bank-sf-b"
    ? [{ ...transaction, transactionId: "pending-sf-b", booked: false, transactionAmount: { amount: "-1.00", currency: "EUR" } }]
    : [];
  return { transactions: { all: [transaction, ...pending], booked: [transaction], pending },
    balances: [], startingBalance: 98766 };
}
const server = http.createServer(async (request, response) => {
  try {
    if (request.url === "/test/requests") {
      response.end(JSON.stringify(requests));
      return;
    }
    if (request.url?.startsWith("/test/mode/")) {
      failureMode = request.url.slice("/test/mode/".length);
      response.end("{}");
      return;
    }
    assert.equal(request.method, "POST");
    assert.equal(request.headers["x-actual-token"], "disposable-bank-token");
    let body = "";
    for await (const chunk of request) body += chunk;
    const args = JSON.parse(body);
    requests.push({ path: request.url, accountIds: Array.isArray(args.accountId) ? args.accountId : [args.accountId] });
    response.setHeader("Content-Type", "application/json");
    if (request.url === "/simplefin/transactions") {
      assert.ok(Array.isArray(args.accountId), "SimpleFIN must use batch requests, including one account");
      assert.ok(args.accountId.length > 0, "An empty list must never reach the server");
      assert.ok(args.accountId.every(id => ["bank-sf-a", "bank-sf-b"].includes(id)));
      if (failureMode === "simplefin-missing") {
        response.end(JSON.stringify({ status: "ok", data: {} }));
      } else {
        response.end(JSON.stringify({ status: "ok", data: Object.fromEntries(args.accountId.map(id => [id, data(id)])) }));
      }
    } else if (request.url === "/gocardless/transactions") {
      assert.ok(["bank-checking", "bank-rate"].includes(args.accountId), "Unselected account reached bank provider");
      assert.equal(args.requisitionId, "external-bank");
      if (failureMode === "unauthorized") {
        response.writeHead(401);
        response.end(JSON.stringify({ reason: "unauthorized", details: "token-not-found" }));
      } else if (args.accountId === "bank-rate" && failureMode !== "success") {
        response.end(JSON.stringify({ status: "ok", data: {
          error_type: failureMode === "reauth" ? "ITEM_ERROR" : "RATE_LIMIT_EXCEEDED",
          error_code: failureMode === "reauth" ? "ITEM_LOGIN_REQUIRED" : "RATE_LIMIT_EXCEEDED",
        } }));
      } else {
        response.end(JSON.stringify({ status: "ok", data: data(args.accountId) }));
      }
    } else throw new Error(`Unexpected network request: ${request.url}`);
  } catch (error) {
    console.error(error);
    process.exitCode = 1;
    response.writeHead(500);
    response.end(JSON.stringify({ status: "error" }));
  }
});
await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
try {
  const url = `http://127.0.0.1:${server.address().port}`;
  const child = spawn(".build/engine-bank-sync", ["Native/Resources", directory, url], { stdio: "inherit" });
  const code = await new Promise((resolve, reject) => { child.once("error", reject); child.once("exit", resolve); });
  assert.equal(code, 0, "Native bank sync harness failed");
  assert.ok(requests.length > 0);
  console.log("PASS: all bank traffic stayed on the disposable local fixture");
} finally {
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
  fs.rmSync(directory, { recursive: true, force: true });
}
