import { init, lib } from "@actual/core";
import { getPrefs } from "@actual/prefs";
import { setServer } from "@actual/server-config";
import { createPayee } from "@actual/source/server/accounts/payees.ts";
import { getBudgetType } from "@actual/source/server/budget/base.ts";
import { loadKey } from "@actual/source/server/encryption/index.ts";
import { runMutator } from "@actual/source/server/mutators.ts";
import { currentMonth, sheetForMonth } from "@actual/source/shared/months.ts";
import { makeChild, recalculateSplit } from "@actual/source/shared/transactions.ts";
import * as storage from "@actual/storage";
import { setSyncingMode, fullSync, clearFullSyncTimeout } from "@actual/sync";

import { native } from "./native";
import { uploadSnapshotIfDue } from "./adapters/cloud-storage";
import { canSyncBank, syncBankAccounts } from "./bank-sync";
import {
  clearedBalance,
  createReconciliationTransaction,
  finishReconciliation,
  setCleared,
  unlockTransaction,
} from "./reconcile";

declare function _reply(id: string, ok: boolean, payload: string): void;
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
// Some upstream failures, such as FileUploadError, are thrown as plain objects.
function describe(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === "string") return error;
  if (error && typeof error === "object") {
    if ("message" in error && typeof error.message === "string" && error.message) return error.message;
    if ("reason" in error && typeof error.reason === "string") return "Actual reported an error: " + error.reason;
  }
  return "The operation could not finish. Try again.";
}
function fail(result: unknown) {
  if (result && typeof result === "object" && "error" in result && result.error)
    throw new Error(typeof result.error === "string" ? result.error : JSON.stringify(result.error));
  return result;
}
// desktop-client's shouldApplyRuleChange: rules fill empty fields and may
// extend notes, but never replace what the user entered.
function ruleMayChange(field: string, current: unknown, next: unknown): boolean {
  if (current == null || current === "" || current === 0 || current === false) return true;
  if (field !== "notes" || typeof current !== "string" || typeof next !== "string" || next === current)
    return false;
  const index = next.indexOf(current);
  if (index === -1) return false;
  const prepended = next.slice(0, index);
  const appended = next.slice(index + current.length);
  return !(
    (prepended === "" || current.startsWith(prepended)) &&
    (appended === "" || current.endsWith(appended))
  );
}
let ready = false;
type SyncWarning = { kind: "dropped" | "newer-version"; message: string };
function syncWarning(): SyncWarning | null {
  // Newer-version changes can only apply after an app update, so check them first.
  const tables = lib.db.runQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'messages_pending'",
    [],
    true,
  );
  if (tables.length && lib.db.runQuery("SELECT 1 FROM messages_pending LIMIT 1", [], true).length)
    return {
      kind: "newer-version",
      message:
        "This budget contains changes from a newer Actual version. Update this app before editing or syncing again.",
    };
  if (storage.getItemSync(droppedSyncKey()) === true)
    return {
      kind: "dropped",
      message:
        "Some changes made on another device could not be applied on this device, so your devices may show different values. Edits and sync are paused until you review this.",
    };
  return null;
}
function droppedSyncKey() {
  return "native-dropped-sync:" + getPrefs()?.id;
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
      storage.setItemSync(droppedSyncKey(), true);
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
function checkMonth(month: string) {
  if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(month)) throw new Error("Invalid budget month");
}
// Budget metadata, accounts with balances, and payees.
async function overview() {
  const preferences = await lib.send("preferences/get");
  const rawAccounts = await lib.send("accounts-get");
  const payees = await lib.send("api/payees-get");
  const accounts = [];
  for (const account of rawAccounts) {
    accounts.push({
      id: account.id,
      name: account.name,
      // Like Actual's account balance, include future-dated transactions.
      balance: (await lib.send("account-properties", { id: account.id })).balance,
      closed: Boolean(account.closed),
      offbudget: Boolean(account.offbudget),
      bankSyncEnabled: canSyncBank(account),
      bankSyncStatus: account.bank_sync_status,
      lastBankSync: account.last_sync,
      clearedBalance: await clearedBalance(account.id),
      // The latest balance reported by a linked bank, offered when reconciling.
      bankBalance: account.balance_current,
      lastReconciled: account.last_reconciled,
    });
  }
  return {
    cloudFileId: getPrefs()?.cloudFileId ?? null,
    budgetName: getPrefs()?.budgetName || "Budget",
    currencyCode: /^[A-Z]{3}$/.test(preferences.defaultCurrencyCode || "")
      ? preferences.defaultCurrencyCode
      : "",
    syncWarning: syncWarning(),
    accounts,
    payees: payees.filter((p) => !p.transfer_acct).map((p) => ({ id: p.id, name: p.name })),
  };
}
// One month of the budget: its summary and visible category groups.
async function budgetMonth(month: string) {
  checkMonth(month);
  const budget = await lib.send("api/budget-month", { month });
  const budgetType = getBudgetType() === "tracking" ? "tracking" : "envelope";
  // Tracking budgets have no to-budget cell. Mirror the mobile web summary:
  // projected savings for current/future months, actual savings for past ones.
  const savedIsProjected = budgetType === "tracking" && month >= currentMonth();
  const saved =
    budgetType === "tracking"
      ? (
          await lib.send("get-cell", {
            sheetName: sheetForMonth(month),
            name: savedIsProjected ? "total-saved" : "real-saved",
          })
        ).value
      : null;
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
    month,
    budgetType,
    toBudget: budgetType === "envelope" ? (budget.toBudget ?? 0) : null,
    saved: budgetType === "tracking" ? (typeof saved === "number" ? saved : 0) : null,
    savedIsProjected,
    // Envelope budgets negate their budgeted total; tracking budgets do not.
    totalBudgeted: budgetType === "envelope" ? -budget.totalBudgeted : budget.totalBudgeted,
    totalSpent: budget.totalSpent,
    groups,
  };
}
// Every transaction, newest first, with split children grouped under parents.
async function register() {
  const payees = await lib.send("api/payees-get");
  const categories = [
    ...(await lib.send("api/categories-get", {})),
    ...(await lib.send("api/categories-get", { hidden: true })),
  ];
  const payeeMap = new Map(payees.map((p) => [p.id, p]));
  const categoryMap = new Map(categories.map((c) => [c.id, c]));
  const rows = await lib.send("api/transactions-get", {});
  const transactions = rows.map((row) => {
    const payee = row.payee ? payeeMap.get(row.payee) : undefined;
    return {
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
    };
  });
  return transactions.sort((a, b) => b.date.localeCompare(a.date) || a.id.localeCompare(b.id));
}
// Reconciled transactions need the user's confirmation, as in Actual. It must
// be given for the transaction as it is now, not as it was when an editor opened.
async function editable(id: string, allowReconciled: boolean) {
  const { data: rows } = await lib.send(
    "query",
    lib.q("transactions").filter({ id }).select("*").serialize(),
  );
  const row = rows[0];
  if (!row) throw new Error("Transaction no longer exists");
  if (row.is_parent || row.is_child || row.transfer_id)
    throw new Error("Edit split transactions and transfers in Actual for now.");
  if (row.reconciled && !allowReconciled)
    throw new Error("This transaction was reconciled after you opened it. Close it and open it again to review your change.");
  return row;
}
async function perform(method: string, args: Obj): Promise<unknown> {
  await start();
  if (
    [
      "saveTransaction", "deleteTransaction", "budget", "sync", "syncAccounts", "setCleared",
      "unlockTransaction", "createReconciliationTransaction", "finishReconciliation",
    ].includes(method)
  ) {
    const warning = syncWarning();
    if (warning) throw new Error(warning.message);
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
    // Incoming sync messages can apply between awaits. Read each part
    // coherently using the same serialization as upstream mutations.
    case "overview":
      return runMutator(overview);
    case "budgetMonth":
      return runMutator(() => budgetMonth(text(args.month)));
    case "register":
      return runMutator(register);
    case "acknowledgeSyncWarning": {
      // Actual only warns when another device's changes are discarded; this
      // device may then show different values for them. Once the user accepts
      // that, continue as Actual does. Newer-version changes stay blocked.
      if (!getPrefs()?.id) throw new Error("Open a budget first.");
      if (syncWarning()?.kind !== "dropped") throw new Error("There is no warning to dismiss.");
      await storage.removeItem(droppedSyncKey());
      return {};
    }
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
        if (warning) throw new Error(warning.message);
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
      const existing = id ? await editable(id, args.allowReconciled === true) : null;
      const accountId = text(args.accountId),
        date = text(args.date);
      if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new Error("Choose a valid date.");
      let payee = text(args.payeeId) || null;
      const name = text(args.payeeName).trim();
      // Like Actual, reuse an existing payee whose name differs only in case.
      if (!payee && name) payee = await runMutator(() => createPayee(name));
      const account = (await lib.send("accounts-get")).find((a) => a.id === accountId);
      if (!account) throw new Error("This account no longer exists. Choose another account.");
      const fields = {
        account: accountId,
        date,
        payee,
        // Actual never categorizes off-budget transactions.
        category: account?.offbudget ? null : text(args.categoryId) || null,
        amount: integer(args.amount),
        notes: text(args.notes),
        // A reconciled transaction stays cleared until it is unlocked.
        cleared: existing?.reconciled ? Boolean(existing.cleared) : Boolean(args.cleared),
      };
      if (existing) {
        // Like Actual's editors, send only changed fields. Rewriting unchanged
        // columns would override other devices' edits that have not synced yet.
        // The handler is a mutator; lib.send awaits it under Actual's lock.
        const changes = Object.fromEntries(
          Object.entries(fields).filter(([key, value]) =>
            key === "notes" ? (existing.notes || "") !== value : (existing[key] ?? null) !== value,
          ),
        );
        // Like Actual's desktop editor, moving a transaction to another account unlocks it.
        if (existing.reconciled && "account" in changes) Object.assign(changes, { reconciled: false });
        if (Object.keys(changes).length)
          await lib.send("transactions-batch-update", { updated: [{ id, ...changes }] });
      } else {
        // Like Actual's mobile editor, run rules on the new transaction but keep
        // what the user entered: rules fill empty fields and may extend notes.
        // A rule's payee always applies, as when a payee is chosen in Actual.
        // The batch handler saves without running rules again.
        const draft = {
          id: crypto.randomUUID(),
          sort_order: Date.now(),
          ...fields,
          payee: fields.payee ?? undefined,
          category: fields.category ?? undefined,
        };
        const ruled = await lib.send("rules-run", { transaction: draft });
        const transaction = { ...draft };
        for (const field of Object.keys(fields) as Array<keyof typeof fields>) {
          if (
            ruled[field] !== draft[field] &&
            (field === "payee" || ruleMayChange(field, draft[field], ruled[field]))
          )
            Object.assign(transaction, { [field]: ruled[field] });
        }
        const children = ruled.subtransactions ?? [];
        if (children.length) {
          // A split rule: store the parent and children as upstream imports do.
          const { subtransactions = [], ...parent } = recalculateSplit({
            ...ruled,
            ...transaction,
            is_parent: true,
            subtransactions: children.map((child, index) =>
              makeChild(transaction, { ...child, sort_order: 0 - index }),
            ),
          });
          await lib.send("transactions-batch-update", { added: [parent, ...subtransactions] });
        } else await lib.send("transactions-batch-update", { added: [transaction] });
      }
      return {};
    }
    case "deleteTransaction": {
      const id = text(args.id);
      await editable(id, args.allowReconciled === true);
      await lib.send("transactions-batch-update", { deleted: [{ id }] });
      return {};
    }
    case "setCleared": {
      if (typeof args.cleared !== "boolean") throw new Error("Choose whether the transaction is cleared.");
      await setCleared(text(args.id), args.cleared);
      return {};
    }
    case "unlockTransaction": {
      await unlockTransaction(text(args.id));
      return {};
    }
    case "createReconciliationTransaction": {
      await createReconciliationTransaction(text(args.accountId), integer(args.targetBalance));
      return {};
    }
    case "finishReconciliation": {
      await finishReconciliation(text(args.accountId), integer(args.targetBalance), args.lock === true);
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
        throw new Error(
          describe(error) + " Previous budget could not be reopened: " + describe(recoveryError),
        );
      }
    }
    throw error;
  }
}
let queue: Promise<unknown> = Promise.resolve();
let activeSync: Promise<unknown> | null = null;
export function request(id: string, method: string, argsJSON: string) {
  // Pass the result's JSON through untouched; native decodes it off the main thread.
  const reply = (value: unknown) => _reply(id, true, JSON.stringify(value ?? null));
  const reject = (error: unknown) => _reply(id, false, describe(error));
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
