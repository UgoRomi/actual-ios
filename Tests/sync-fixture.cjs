const fs = require("node:fs");
const path = require("node:path");
const assert = require("node:assert/strict");
const source = process.env.ACTUAL_SOURCE;
const api = require(path.join(source, "packages/api/dist/index.js"));
const dir = process.argv[2],
  phase = process.argv[3];
const serverURL = process.env.NATIVE_TEST_SERVER || "http://127.0.0.1:15066";
const password = "disposable-native-sync-test";
const encryptionPassword = "disposable-encryption-test";
(async () => {
  fs.mkdirSync(dir, { recursive: true });
  if (phase === "create") {
    const res = await fetch(serverURL + "/account/bootstrap", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ password }),
    });
    const body = await res.json();
    if (body.status !== "ok") throw new Error(JSON.stringify(body));
  }
  const internal = await api.init({
    dataDir: dir,
    serverURL,
    password,
    verbose: false,
  });
  if (phase === "create") {
    await internal.send("create-budget", {
      budgetName: "Native Sync Fixture",
      avoidUpload: true,
    });
    const accountId = await api.createAccount({ name: "Test Checking" }, 100000);
    const ruleAccountId = await api.createAccount({ name: "Rule Checking" }, 0);
    const transferAccountId = await api.createAccount({ name: "Rule Savings" }, 0);
    const transferPayee = (await api.getPayees()).find(
      (p) => p.transfer_acct === transferAccountId,
    );
    assert.ok(transferPayee);
    await api.createRule({
      stage: "pre",
      conditionsOp: "and",
      conditions: [{ field: "notes", op: "is", value: "native transfer rule" }],
      actions: [{ field: "payee", op: "set", value: transferPayee.id }],
    });
    const categories = await api.getCategories();
    const category = categories.find((c) => !c.is_income);
    assert.ok(category);
    const upload = await internal.send("upload-budget");
    if (upload?.error) throw new Error(JSON.stringify(upload));
    const encryption = await internal.send("key-make", {
      password: encryptionPassword,
    });
    if (encryption?.error) throw new Error(JSON.stringify(encryption));
    const budgets = await api.getBudgets();
    const remote = budgets.find((b) => b.groupId && b.name === "Native Sync Fixture");
    assert.ok(remote);
    fs.writeFileSync(
      path.join(dir, "fixture.json"),
      JSON.stringify({
        url: serverURL,
        password,
        encryptionPassword,
        syncId: remote.groupId,
        accountId,
        ruleAccountId,
        transferAccountId,
        categoryId: category.id,
      }),
    );
    console.log("Encrypted disposable fixture created");
  } else {
    const fixture = JSON.parse(fs.readFileSync(path.join(dir, "fixture.json"), "utf8"));
    await api.downloadBudget(fixture.syncId, { password: encryptionPassword });
    await api.sync();
    const transactions = await api.getTransactions(fixture.accountId, "2026-01-01", "2026-12-31");
    const transaction = transactions.find((t) => t.notes === "native offline restart");
    assert.ok(transaction, "Native transaction arrived via sync");
    assert.equal(transaction.amount, -2345);
    assert.equal(await api.getAccountBalance(fixture.accountId), 97655);
    const ruleRows = await api.getTransactions(fixture.ruleAccountId, "2026-01-01", "2026-12-31");
    const transferRows = await api.getTransactions(
      fixture.transferAccountId,
      "2026-01-01",
      "2026-12-31",
    );
    // The offline edit came from the receiving side; both sides carry it.
    const source = ruleRows.find((t) => t.notes === "native transfer edit");
    assert.ok(source?.transfer_id, "Rule-created transfer has a matching entry");
    const target = transferRows.find((t) => t.id === source.transfer_id);
    assert.equal(target?.transfer_id, source.id);
    assert.equal(target.notes, "native transfer edit");
    assert.equal(source.amount, -5000);
    assert.equal(target.amount, 5000);
    assert.equal(await api.getAccountBalance(fixture.ruleAccountId), -5000);
    assert.equal(await api.getAccountBalance(fixture.transferAccountId), 5000);
    console.log("PASS: rule-created native transfer, edited offline from its other side, syncs both entries and exact balances");
    console.log("PASS: upstream Actual API sees native encrypted offline edit and exact balance");
  }
  await api.shutdown();
})().catch(async (error) => {
  console.error(error);
  await api.shutdown().catch(() => {});
  process.exit(1);
});
