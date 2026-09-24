import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";

const source = process.env.ACTUAL_SOURCE;
const require = createRequire(import.meta.url);
const api = require(path.join(source, "packages/api/dist/index.js"));
const directory = fs.mkdtempSync(path.join(os.tmpdir(), "actual-auto-sync-"));
fs.mkdirSync(path.join(directory, "server"));
fs.mkdirSync(path.join(directory, "remote"));
const log = fs.openSync(path.join(directory, "server.log"), "w");
const listen = server => new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(0, "127.0.0.1", () => resolve(server.address().port));
});
const probe = http.createServer();
const port = await listen(probe);
await new Promise(resolve => probe.close(resolve));
const serverURL = `http://127.0.0.1:${port}`;
const server = spawn(process.execPath, [path.join(source, "packages/sync-server/build/app.js")], {
  env: { ...process.env, ACTUAL_DATA_DIR: path.join(directory, "server"), ACTUAL_PORT: String(port), ACTUAL_HOSTNAME: "127.0.0.1", NODE_ENV: "production" },
  stdio: ["ignore", log, log],
});
let native;
let fixture;
let proxy;
let hold = false;
let offline = false;
let rejectUploads = false;
let syncRequests = 0;
let uploadAttempts = 0;
let inFlight = 0;
let maxInFlight = 0;
const pending = [];
const run = (command, args, env = process.env) => new Promise((resolve, reject) => {
  const child = spawn(command, args, { env, stdio: "inherit" });
  child.once("error", reject);
  child.once("exit", code => code === 0 ? resolve() : reject(new Error(`${command} exited ${code}`)));
});
let watchdog;
try {
  for (let attempt = 0; ; attempt++) {
    try { if ((await fetch(serverURL + "/info")).ok) break; } catch {}
    if (attempt === 100 || server.exitCode != null) throw new Error("Fixture server did not start");
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  await run(process.execPath, ["Tests/sync-fixture.cjs", path.join(directory, "fixture"), "create"], {
    ...process.env, NATIVE_TEST_SERVER: serverURL,
  });
  fixture = JSON.parse(fs.readFileSync(path.join(directory, "fixture/fixture.json"), "utf8"));
  await api.init({ dataDir: path.join(directory, "remote"), serverURL, password: fixture.password, verbose: false });
  await api.downloadBudget(fixture.syncId, { password: fixture.encryptionPassword });
  proxy = http.createServer(async (request, response) => {
    try {
      response.setHeader("Content-Type", "application/json");
      if (request.url.startsWith("/test/")) {
        const control = new URL(request.url, "http://fixture");
        const id = control.searchParams.get("id");
        switch (control.pathname) {
          case "/test/hold": hold = true; break;
          case "/test/release": hold = false; pending.splice(0).forEach(release => release()); break;
          case "/test/offline": offline = true; break;
          case "/test/online": offline = false; break;
          case "/test/reject-uploads": rejectUploads = true; break;
          case "/test/accept-uploads": rejectUploads = false; break;
          case "/test/remote-notes":
            await api.sync();
            await api.updateTransaction(id, { notes: "Remote note" });
            await api.sync();
            break;
          case "/test/transaction": {
            await api.sync();
            const row = (await api.getTransactions(fixture.accountId, "2026-01-01", "2026-12-31")).find(row => row.id === id);
            response.end(JSON.stringify({ amount: row?.amount ?? 0, notes: row?.notes ?? "" }));
            return;
          }
          case "/test/remote-edit":
            await api.sync();
            await api.addTransactions(fixture.accountId, [{ date: "2026-09-24", amount: -200, notes: "Remote auto-sync fixture", category: fixture.categoryId }]);
            await api.sync();
            break;
          case "/test/verify": {
            await api.sync();
            const rows = await api.getTransactions(fixture.accountId, "2026-01-01", "2026-12-31");
            const budget = await api.getBudgetMonth("2026-09");
            const category = budget.categoryGroups.flatMap(group => group.categories).find(category => category.id === fixture.categoryId);
            response.end(JSON.stringify({
              amount: rows.find(row => row.notes === "Automatic sync edit")?.amount ?? 0,
              balance: await api.getAccountBalance(fixture.accountId), allocation: category.budgeted,
              deletedPresent: rows.some(row => row.notes === "Delete automatic fixture"),
            }));
            return;
          }
          case "/test/state": break;
          default: throw new Error(`Unknown fixture control ${request.url}`);
        }
        response.end(JSON.stringify({ syncRequests, uploadAttempts, pendingRequests: pending.length, inFlight, maxInFlight }));
        return;
      }
      const isSync = request.url === "/sync/sync";
      if (isSync) {
        syncRequests++;
        inFlight++;
        maxInFlight = Math.max(maxInFlight, inFlight);
        response.once("close", () => { inFlight--; });
      }
      const chunks = [];
      for await (const chunk of request) chunks.push(chunk);
      if (request.url === "/sync/upload-user-file") {
        uploadAttempts++;
        if (rejectUploads) {
          response.writeHead(500);
          response.end(JSON.stringify({ status: "error", reason: "internal" }));
          return;
        }
      }
      if (isSync && hold) await new Promise(resolve => pending.push(resolve));
      if (isSync && offline) {
        response.writeHead(503);
        response.end(JSON.stringify({ reason: "network-failure" }));
        return;
      }
      const upstream = http.request(serverURL + request.url, { method: request.method, headers: request.headers }, result => {
        response.writeHead(result.statusCode, result.headers);
        result.pipe(response);
      });
      upstream.on("error", () => { response.writeHead(502); response.end("{}"); });
      upstream.end(Buffer.concat(chunks));
    } catch (error) {
      console.error(error);
      process.exitCode = 1;
      response.writeHead(500);
      response.end("{}");
    }
  });
  const proxyPort = await listen(proxy);
  native = spawn(".build/automatic-budget-sync", ["Native/Resources", path.join(directory, "native"), path.join(directory, "fixture/fixture.json"), `http://127.0.0.1:${proxyPort}`], { stdio: "inherit" });
  watchdog = setTimeout(() => { console.error("Automatic sync fixture timed out"); native.kill("SIGKILL"); }, 90000);
  const code = await new Promise((resolve, reject) => { native.once("error", reject); native.once("exit", resolve); });
  assert.equal(code, 0, "Native automatic-sync harness failed");
  assert.equal(maxInFlight, 1, "Budget sync requests must never overlap");
  console.log("PASS: real encrypted server sync with delayed responses, offline failures, rejected snapshot uploads, and no overlapping requests");
} finally {
  clearTimeout(watchdog);
  native?.kill();
  pending.splice(0).forEach(release => release());
  proxy?.closeAllConnections();
  if (proxy) await new Promise(resolve => proxy.close(resolve));
  await api.shutdown().catch(() => {});
  server.kill();
  await new Promise(resolve => { if (server.exitCode != null) resolve(); else server.once("exit", resolve); });
  fs.closeSync(log);
  console.log(`Disposable automatic-sync fixture: ${directory}`);
}
