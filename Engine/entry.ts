import { init, lib } from "@actual/core";
import { getPrefs } from "@actual/prefs";
import { setServer } from "@actual/server-config";
import { loadKey } from "@actual/source/server/encryption/index.ts";
import { runMutator } from "@actual/source/server/mutators.ts";
import * as storage from "@actual/storage";
import { setSyncingMode, fullSync, clearFullSyncTimeout } from "@actual/sync";

import { native } from "./native";
import { uploadSnapshotIfDue } from "./adapters/cloud-storage";
import { canSyncBank, syncBankAccounts } from "./bank-sync";

declare function _reply(id: string, response: string): void;
type Obj = Record<string, unknown>;
function object(value: unknown): Obj {
  if (value && typeof value === "object" && !Array.isArray(value))
    return Object.fromEntries(Object.entries(value));
  throw new Error("Expected an object");
}
function text(value: unknown, fallback = ""): string {
  return typeof value === "string" ? value : fallback;
}
function integer(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value))
    throw new Error("Invalid monetary amount");
  return value;
}
function fail(result: unknown) {
  if (result && typeof result === "object" && "error" in result && result.error)
    throw new Error(typeof result.error === "string" ? result.error : JSON.stringify(result.error));
  return result;
}
let ready = false;
function syncWarning(): string | null {
  if (storage.getItemSync("native-dropped-sync:" + getPrefs()?.id) === true)
    return "Some server changes could not be applied. Review this budget in the current Actual web app before continuing.";
  const tables = lib.db.runQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'messages_pending'",
    [],
    true,
  );
  if (tables.length && lib.db.runQuery("SELECT 1 FROM messages_pending LIMIT 1", [], true).length)
    return "This budget contains changes from a newer Actual version. Update this app before editing or syncing again.";
  return null;
}
async function start() {
  if (ready) return;
  const saved = native<Obj>("settings.read");
  const url = text(saved["server-url"]);
  if (url) await init({ dataDir: "/documents", serverURL: url, password: "", verbose: false });
  else await init({ dataDir: "/documents", verbose: false });
  const savedKeys = await storage.getItem("encrypt-keys");
  if (typeof savedKeys === "string") {
    for (const key of Object.values(object(JSON.parse(savedKeys)))) {
      const value = object(key);
      if (typeof value.id !== "string" || typeof value.base64 !== "string")
        throw new Error("Saved encryption key is invalid");
      await loadKey({ id: value.id, base64: value.base64 });
    }
  }
  lib.on("load-budget", () => {
    setSyncingMode("offline");
  });
  lib.on("sync", (event: unknown) => {
    if (event && typeof event === "object" && "type" in event && event.type === "dropped-messages")
      storage.setItemSync("native-dropped-sync:" + getPrefs()?.id, true);
  });
  setSyncingMode("offline");
  ready = true;
}
async function remember() {
  if (getPrefs()?.id) await storage.setItem("native-last-budget", getPrefs().id);
}
async function budgets() {
  const files = await lib.send("get-budgets");
  return files.map((file) => ({
    id: file.id,
    name: file.name || file.id,
    cloudFileId: file.cloudFileId ?? null,
  }));
}
async function snapshot(month: string) {
  if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(month)) throw new Error("Invalid budget month");
  const budget = await lib.send("api/budget-month", { month });
  const preferences = await lib.send("preferences/get");
  const rawAccounts = await lib.send("accounts-get");
  const payees = await lib.send("api/payees-get");
  const rawCategories = [
    ...(await lib.send("api/categories-get", {})),
    ...(await lib.send("api/categories-get", { hidden: true })),
  ];
  const payeeMap = new Map(payees.map((p) => [p.id, p]));
  const categoryMap = new Map(rawCategories.map((c) => [c.id, c]));
  const accounts = [];
  const transactions = [];
  for (const account of rawAccounts) {
    accounts.push({
      id: account.id,
      name: account.name,
      // The public API wrapper acquires a mutator; snapshot already holds it.
      balance: await lib.send("account-balance", { id: account.id, cutoff: new Date() }),
      closed: Boolean(account.closed),
      offbudget: Boolean(account.offbudget),
      bankSyncEnabled: canSyncBank(account),
      bankSyncStatus: account.bank_sync_status,
      lastBankSync: account.last_sync,
    });
    const rows = await lib.send("api/transactions-get", {
      accountId: account.id,
      startDate: "1900-01-01",
      endDate: "2999-12-31",
    });
    for (const row of rows) {
      const payee = row.payee ? payeeMap.get(row.payee) : undefined;
      transactions.push({
        id: row.id,
        accountId: row.account,
        date: row.date,
        payeeId: row.payee ?? null,
        payeeName: payee?.name ?? null,
        categoryId: row.category ?? null,
        categoryName:
          (row.category ? categoryMap.get(row.category)?.name : undefined) || "Uncategorized",
        amount: row.amount,
        notes: row.notes || "",
        cleared: Boolean(row.cleared),
        isParent: Boolean(row.is_parent),
        isChild: Boolean(row.is_child),
        isTransfer: Boolean(row.transfer_id || payee?.transfer_acct),
        reconciled: Boolean(row.reconciled),
      });
    }
  }
  transactions.sort((a, b) => b.date.localeCompare(a.date) || a.id.localeCompare(b.id));
  const groups = budget.categoryGroups
    .filter((g) => !g.hidden)
    .map((group) => ({
      id: group.id,
      name: group.name,
      categories: (group.categories ?? [])
        .filter((c) => !c.hidden)
        .map((category) => ({
          id: category.id,
          name: category.name,
          budgeted: category.budgeted || 0,
          spent: category.spent ?? category.received ?? 0,
          balance: category.balance || 0,
          isIncome: Boolean(category.is_income),
        })),
    }));
  return {
    cloudFileId: getPrefs()?.cloudFileId ?? null,
    budgetName: getPrefs()?.budgetName || "Budget",
    month,
    currencyCode: /^[A-Z]{3}$/.test(preferences.defaultCurrencyCode || "")
      ? preferences.defaultCurrencyCode
      : "",
    syncWarning: syncWarning(),
    toBudget: budget.toBudget,
    totalBudgeted: -budget.totalBudgeted,
    totalSpent: budget.totalSpent,
    accounts,
    groups,
    transactions,
    payees: payees.filter((p) => !p.transfer_acct).map((p) => ({ id: p.id, name: p.name })),
  };
}
async function editable(id: string) {
  const { data: rows } = await lib.send(
    "query",
    lib.q("transactions").filter({ id }).select("*").serialize(),
  );
  const row = rows[0];
  if (!row) throw new Error("Transaction no longer exists");
  if (row.reconciled) throw new Error("Edit reconciled transactions in Actual for now.");
  if (row.is_parent || row.is_child || row.transfer_id)
    throw new Error("Edit split transactions and transfers in Actual for now.");
  return row;
}
async function perform(method: string, args: Obj): Promise<unknown> {
  await start();
  if (["saveTransaction", "deleteTransaction", "budget", "sync", "syncAccounts"].includes(method)) {
    const warning = syncWarning();
    if (warning) throw new Error(warning);
  }
  switch (method) {
    case "bootstrap": {
      const id = await storage.getItem("native-last-budget");
      if (typeof id === "string" && id) {
        await lib.send("api/load-budget", { id });
      }
      return {
        budgets: await budgets(),
        activeBudgetId: getPrefs()?.id ?? null,
      };
    }
    case "demo": {
      await lib.send("close-budget");
      fail(await lib.send("create-demo-budget"));
      await remember();
      return {};
    }
    case "open": {
      await lib.send("api/load-budget", { id: text(args.id) });
      await remember();
      return {};
    }
    case "snapshot":
      // Incoming sync messages can apply between awaits. Read one coherent
      // snapshot using the same serialization as upstream mutations.
      return runMutator(() => snapshot(text(args.month)));
    case "syncAccounts": {
      if (!getPrefs()?.id) throw new Error("Open a budget before refreshing bank accounts.");
      if (args.accountId !== undefined && (typeof args.accountId !== "string" || !args.accountId))
        throw new Error("Choose a valid account to refresh.");
      return syncBankAccounts(typeof args.accountId === "string" ? args.accountId : undefined);
    }
    case "connect": {
      const url = text(args.url).replace(/\/+$/, "");
      native("validate.url", { url });
      const oldURL = await storage.getItem("server-url");
      const oldToken = await storage.getItem("user-token");
      if (oldURL && oldURL !== url)
        throw new Error(
          "This installation is connected to a different Actual server. Multiple servers are not supported yet.",
        );
      setServer(url);
      try {
        fail(
          await lib.send("subscribe-sign-in", {
            password: text(args.password),
          }),
        );
        await storage.setItem("server-url", url);
        const files = await lib.send("get-remote-files");
        return {
          budgets: (files || [])
            .filter((f) => !f.deleted)
            .map((f) => ({ id: f.groupId, name: f.name, cloudFileId: f.fileId })),
        };
      } catch (error) {
        setServer(typeof oldURL === "string" ? oldURL : null);
        await storage.setItem("user-token", oldToken);
        throw error;
      }
    }
    case "download": {
      try {
        await lib.send("api/download-budget", {
          syncId: text(args.syncId),
          password: text(args.password) || undefined,
        });
      } finally {
        setSyncingMode("offline");
      }
      if (!getPrefs()?.id)
        throw new Error("The downloaded budget could not be opened. Check its version in Actual.");
      await remember();
      return {};
    }
    case "sync": {
      if (!(await storage.getItem("server-url")))
        throw new Error("Connect to your Actual server first.");
      if (!getPrefs()?.cloudFileId)
        throw new Error("This budget is local only. Open a synced budget to synchronize.");
      setSyncingMode("enabled");
      try {
        const result = await fullSync();
        // Stop upstream scheduling before the snapshot upload: fullSync's
        // single-flight guard has settled, but upload may still be waiting.
        setSyncingMode("offline");
        clearFullSyncTimeout();
        if (result && "error" in result) {
          const { reason, message } = result.error;
          if (reason === "network-failure") throw new Error("Could not reach your Actual server. Check your connection and try again.");
          if (reason === "unauthorized" || reason === "token-expired")
            throw new Error("Reconnect to your Actual server in Settings, then try again.");
          throw new Error(message || reason || "Budget sync could not finish. Try again.");
        }
        const warning = syncWarning();
        if (warning) throw new Error(warning);
        await uploadSnapshotIfDue();
      } finally {
        // Local edits during the request may schedule upstream's fire-and-forget
        // timer. Native owns follow-up passes and must observe every failure.
        clearFullSyncTimeout();
        setSyncingMode("offline");
      }
      return {};
    }
    case "budget": {
      await lib.send("api/budget-set-amount", {
        month: text(args.month),
        categoryId: text(args.categoryId),
        amount: integer(args.amount),
      });
      return {};
    }
    case "saveTransaction": {
      const id = text(args.id);
      const existing = id ? await editable(id) : null;
      const accountId = text(args.accountId),
        date = text(args.date);
      if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new Error("Choose a valid date.");
      let payee = text(args.payeeId) || null;
      const name = text(args.payeeName).trim();
      if (!payee && name) payee = await lib.send("api/payee-create", { payee: { name } });
      const fields = {
        account: accountId,
        date,
        payee,
        category: text(args.categoryId) || null,
        amount: integer(args.amount),
        notes: text(args.notes),
        cleared: Boolean(args.cleared),
      };
      // The pinned api/transaction-update/delete wrappers acknowledge before
      // awaiting their batch result. Await the underlying mutation instead.
      if (id)
        await runMutator(() => lib.send("transaction-update", { ...existing, id, ...fields }), {
          undoDisabled: true,
        });
      else
        await lib.send("api/transactions-add", {
          accountId,
          transactions: [
            { ...fields, category: fields.category ?? undefined, payee: fields.payee ?? undefined },
          ],
          learnCategories: false,
          runTransfers: true,
        });
      return {};
    }
    case "deleteTransaction": {
      const id = text(args.id);
      await editable(id);
      await runMutator(() => lib.send("transaction-delete", { id }), {
        undoDisabled: true,
      });
      return {};
    }
    case "close":
      await lib.send("close-budget");
      await storage.removeItem("native-last-budget");
      return {};
    default:
      throw new Error("Unknown operation: " + method);
  }
}
async function execute(method: string, args: Obj): Promise<unknown> {
  await start();
  const previousId = getPrefs()?.id;
  try {
    return await perform(method, args);
  } catch (error) {
    if (["open", "download", "demo"].includes(method) && previousId) {
      try {
        await lib.send("close-budget");
        await lib.send("api/load-budget", { id: previousId });
        await remember();
      } catch (recoveryError) {
        const original = error instanceof Error ? error.message : String(error);
        const recovery =
          recoveryError instanceof Error ? recoveryError.message : String(recoveryError);
        throw new Error(original + " Previous budget could not be reopened: " + recovery);
      }
    }
    throw error;
  }
}
let queue: Promise<unknown> = Promise.resolve();
let activeSync: Promise<unknown> | null = null;
export function request(id: string, method: string, argsJSON: string) {
  const reply = (value: unknown) => _reply(id, JSON.stringify({ value: value ?? null }));
  const reject = (error: unknown) => _reply(id, JSON.stringify({
    error: error instanceof Error ? error.message : String(error),
  }));
  queue = queue.then(async () => {
    const args = object(JSON.parse(argsJSON));
    if (method === "sync") {
      await start();
      if (!activeSync) activeSync = execute(method, args).finally(() => { activeSync = null; });
      // Release the command queue during network waits. Actual serializes
      // incoming messages with local mutations on this same JS runtime.
      void activeSync.then(reply, reject);
      return;
    }
    if (["bootstrap", "open", "download", "demo", "close", "connect"].includes(method)) {
      // A sync must finish against the budget/server with which it started.
      await activeSync?.catch(() => {});
    }
    reply(await execute(method, args));
  }).catch(reject);
}
