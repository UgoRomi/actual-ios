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
    // Less the native split's 3,000.
    assert.equal(await api.getAccountBalance(fixture.accountId), 94655);
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
    // Plus the native split's 2,000 transfer part.
    assert.equal(await api.getAccountBalance(fixture.transferAccountId), 7000);
    console.log("PASS: rule-created native transfer, edited offline from its other side, syncs both entries and exact balances");

    // This app's other offline edits, as Actual sees them after sync.
    const month = await api.getBudgetMonth("2026-09");
    const budgeted = month.categoryGroups.flatMap((g) => g.categories).find((c) => c.id === fixture.categoryId);
    assert.equal(budgeted.budgeted, 12345);
    assert.equal(budgeted.carryover, true, "Rollover set natively");
    const groups = await api.getCategoryGroups();
    const group = groups.find((g) => g.name === "Native Sync Group");
    const category = group?.categories?.find((c) => c.name === "Native Sync Category");
    assert.ok(category, "Native category group and category arrived");
    assert.equal((await api.getNote(category.id))?.note, "native sync note");
    const split = transactions.find((t) => t.notes === "native sync split");
    assert.ok(split?.is_parent, "Native split arrived");
    assert.equal(split.amount, -3000);
    const parts = split.subtransactions;
    assert.equal(parts.length, 2);
    assert.deepEqual(parts.map((p) => p.amount).sort((a, b) => a - b), [-2000, -1000]);
    assert.equal(parts.find((p) => p.amount === -1000).category, category.id);
    const transferPart = parts.find((p) => p.amount === -2000);
    const linked = transferRows.find((t) => t.id === transferPart.transfer_id);
    assert.equal(linked?.amount, 2000, "The transfer part has its other side");
    const payees = await api.getPayees();
    assert.ok(payees.some((p) => p.name === "Native Sync Store" && p.id === split.payee), "Payee renamed natively");
    const schedule = (await api.getSchedules()).find((s) => s.name === "Native Sync Schedule");
    assert.ok(schedule, "Native schedule arrived");
    assert.equal(schedule.amount, -777);
    assert.equal(schedule.next_date, "2026-10-01");
    const rules = await api.getRules();
    const rule = rules.find((r) => r.conditions.some((c) => c.value === "native sync rule"));
    assert.equal(rule?.actions[0].value, category.id, "Native rule arrived");
    assert.equal((await internal.send("preferences/get")).numberFormat, "dot-comma");
    const widgets = (await api.aqlQuery(api.q("dashboard").filter({ type: "net-worth-card" }).select("*"))).data;
    const widget = widgets.find((w) => w.meta?.name === "Native Sync Widget");
    assert.equal(widget?.meta.interval, "Weekly", "Native widget edit arrived");
    console.log("PASS: upstream Actual API sees native budget moves, categories, notes, split transfer, payee, schedule, rule, setting, and dashboard widget");
    console.log("PASS: upstream Actual API sees native encrypted offline edit and exact balance");
  }
  await api.shutdown();
})().catch(async (error) => {
  console.error(error);
  await api.shutdown().catch(() => {});
  process.exit(1);
});
