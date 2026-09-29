import { init, lib } from "@actual/core";
import { getPrefs } from "@actual/prefs";
import { getServer, setServer } from "@actual/server-config";
import { createPayee } from "@actual/source/server/accounts/payees.ts";
import { getBudgetType } from "@actual/source/server/budget/base.ts";
import { getCategoriesWithTemplateNotes } from "@actual/source/server/budget/statements.ts";
import { loadKey } from "@actual/source/server/encryption/index.ts";
import { runMutator } from "@actual/source/server/mutators.ts";
import * as sheet from "@actual/source/server/sheet.ts";
import { currentMonth, sheetForMonth } from "@actual/source/shared/months.ts";
import { makeChild, recalculateSplit } from "@actual/source/shared/transactions.ts";
import * as storage from "@actual/storage";
import { setSyncingMode, fullSync, clearFullSyncTimeout } from "@actual/sync";

import { native } from "./native";
import { uploadSnapshotIfDue } from "./adapters/cloud-storage";
import { canSyncBank, syncBankAccounts } from "./bank-sync";
import { budgetAction, envelopeSummary } from "./budget-actions";
import { manage, managementMethods } from "./management";
import { ruleCommand, rulesList, ruleWrites } from "./rules";
import { commitImport, prepareImport } from "./importing";
import { saveSplit } from "./splits";
import { scheduleCommand, schedulePreviews, schedules, scheduleWrites } from "./schedules";
import {
  clearedBalance,
  createReconciliationTransaction,
  finishReconciliation,
  setCleared,
  unlockTransaction,
} from "./reconcile";
import { dashboard, report, reportTransactions } from "./reports";
import { applyTargets, categoryTargets, previewTargets, saveTargets } from "./targets";

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
// One server per installation: any server until one is connected, then only that one.
async function serverURL(value: unknown): Promise<string> {
  const url = text(value).replace(/\/+$/, "");
  native("validate.url", { url });
  const connected = await storage.getItem("server-url");
  if (connected && connected !== url)
    throw new Error(
      "This installation is connected to a different Actual server. Multiple servers are not supported yet.",
    );
  return url;
}
// Asks a server that may not be connected yet, then restores the connected one.
async function withServer<T>(url: string, body: () => Promise<T>): Promise<T> {
  const previous = getServer()?.BASE_SERVER ?? null;
  setServer(url);
  try {
    return await body();
  } finally {
    setServer(previous);
  }
}
const unreachable = "Could not reach your Actual server. Check the address and your connection.";
function openIdError(reason: string, password: string): string {
  switch (reason) {
    // Actual asks for the server password when no one has signed in with OpenID yet.
    case "invalid-password":
      return password
        ? "The server password is incorrect."
        : "Enter the server password to confirm the first OpenID sign-in.";
    case "network-failure":
      return unreachable;
    case "openid-not-configured":
      return "OpenID is not set up on this server.";
    case "openid-setup-failed":
      return "Your server could not reach its OpenID provider. Check the OpenID settings in Actual.";
    case "Invalid redirect URL":
      return "Your server could not start OpenID sign-in for this app. Check the OpenID settings in Actual.";
    default:
      return "OpenID sign-in could not start: " + reason;
  }
}
// A session token from the server's OpenID callback, kept only if the server accepts it.
async function useSessionToken(token: string) {
  if (!token) throw new Error("OpenID sign-in did not finish. Try again.");
  await lib.send("subscribe-set-token", { token });
  const user = await lib.send("subscribe-get-user");
  if (user?.offline) throw new Error(unreachable);
  if (!user || ("tokenExpired" in user && user.tokenExpired))
    throw new Error("Your server did not accept this sign-in. Try again.");
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
      notes:
        (lib.db.runQuery("SELECT note FROM notes WHERE id = ?", ["account-" + account.id], true) as Obj[])[0]
          ?.note ?? null,
    });
  }
  return {
    cloudFileId: getPrefs()?.cloudFileId ?? null,
    budgetName: getPrefs()?.budgetName || "Budget",
    currencyCode: /^[A-Z]{3}$/.test(preferences.defaultCurrencyCode || "")
      ? preferences.defaultCurrencyCode
      : "",
    syncWarning: syncWarning(),
    // Actual's formatting settings, which sync between devices. Unset ones follow the device.
    format: {
      numberFormat: preferences.numberFormat || null,
      hideFraction: String(preferences.hideFraction) === "true",
      dateFormat: preferences.dateFormat || null,
      firstDayOfWeekIdx: preferences.firstDayOfWeekIdx ? Number(preferences.firstDayOfWeekIdx) : null,
      upcomingLength: preferences.upcomingScheduledTransactionLength || "7",
    },
    accounts,
    payees: payees.filter((p) => !p.transfer_acct).map((p) => ({ id: p.id, name: p.name })),
    // Tags color #tags in notes, as Actual shows them.
    tags: (await lib.send("tags-get")).map((t) => ({
      id: t.id,
      tag: t.tag,
      color: t.color ?? null,
      description: t.description ?? null,
      hidden: Boolean(t.hidden),
    })),
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
  // Categories with targets, from the editor or from notes Actual has yet to
  // read. Applying targets sets each category's goal for the month.
  const { data: rows } = await lib.send(
    "query",
    lib.q("categories").select(["id", "goal_def", "template_settings"]).serialize(),
  );
  const noted = new Set((await getCategoriesWithTemplateNotes()).map((c) => c.id));
  const targeted = new Set<string>(
    rows
      .filter((c: Obj) => c.goal_def || (object(c.template_settings ?? {}).source !== "ui" && noted.has(text(c.id))))
      .map((c: Obj) => text(c.id)),
  );
  const cell = (name: string) => {
    const value = sheet.getCellValue(sheetForMonth(month), name);
    return typeof value === "number" ? value : null;
  };
  // Notes for categories, groups, and this month, as Actual's notes buttons show them.
  const notes = new Map(
    (lib.db.runQuery("SELECT id, note FROM notes WHERE note IS NOT NULL AND note != ''", [], true) as Obj[]).map(
      (row) => [text(row.id), text(row.note)],
    ),
  );
  // Hidden groups and categories are included, flagged, so the app can show them on request.
  const groups = budget.categoryGroups
    .map((group) => ({
      id: group.id,
      name: group.name,
      hidden: Boolean(group.hidden),
      isIncome: Boolean(group.is_income),
      notes: notes.get(text(group.id)) ?? null,
      // Actual's group totals, as its mobile budget's group headers show them.
      budgeted: group.budgeted || 0,
      spent: group.spent ?? group.received ?? 0,
      balance: group.balance || 0,
      categories: (group.categories ?? [])
        .map((category) => ({
          id: category.id,
          name: category.name,
          hidden: Boolean(category.hidden),
          notes: notes.get(text(category.id)) ?? null,
          budgeted: category.budgeted || 0,
          spent: category.spent ?? category.received ?? 0,
          balance: category.balance || 0,
          isIncome: Boolean(category.is_income),
          hasTargets: targeted.has(text(category.id)),
          goal: cell("goal-" + category.id),
          // A long-term goal compares the balance with the goal, not the budgeted amount.
          longGoal: cell("long-goal-" + category.id) === 1,
          // Overspending rolls over into next month instead of reducing To Budget.
          carryover: Boolean(sheet.getCellValue(sheetForMonth(month), "carryover-" + category.id)),
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
    envelope: budgetType === "envelope" ? envelopeSummary(month) : null,
    notes: notes.get("budget-" + month) ?? null,
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
  // A transfer's linked transaction may be a split child, which rows group under its parent.
  const byId = new Map(
    rows.flatMap((row) => [row, ...(row.subtransactions ?? [])]).map((row) => [row.id, row]),
  );
  const transactions = rows.map((row) => {
    const payee = row.payee ? payeeMap.get(row.payee) : undefined;
    const linked = row.transfer_id ? byId.get(row.transfer_id) : undefined;
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
      // As in Actual, a transfer's payee stands for the other account.
      transferAccountId: payee?.transfer_acct ?? null,
      transferId: row.transfer_id ?? null,
      transferReconciled: Boolean(linked?.reconciled),
      transferInSplit: Boolean(linked?.is_child),
      // A split's parts, in Actual's order.
      splits: row.is_parent
        ? (row.subtransactions ?? []).map((child) => ({
            id: child.id,
            amount: child.amount,
            categoryId: child.category ?? null,
            categoryName: child.category ? categoryMap.get(child.category)?.name ?? null : null,
            notes: child.notes || "",
            payeeId: child.payee ?? null,
            payeeName: child.payee ? payeeMap.get(child.payee)?.name ?? null : null,
            // A part that is a transfer names the other account, as its payee.
            transferAccountId: child.payee ? payeeMap.get(child.payee)?.transfer_acct ?? null : null,
            isTransfer: Boolean(child.transfer_id || (child.payee && payeeMap.get(child.payee)?.transfer_acct)),
          }))
        : null,
    };
  });
  return transactions.sort((a, b) => b.date.localeCompare(a.date) || a.id.localeCompare(b.id));
}
// Reconciled transactions need the user's confirmation, as in Actual, and so
// does a transfer whose linked transaction is reconciled. It must be given for
// both as they are now, not as they were when an editor opened.
async function editable(id: string, allowReconciled: boolean, allowReconciledTransfer: boolean, wholeSplit = false) {
  const find = async (transactionId: string) =>
    (
      await lib.send(
        "query",
        lib.q("transactions").filter({ id: transactionId }).select("*").options({ splits: "all" }).serialize(),
      )
    ).data[0];
  const row = await find(id);
  if (!row) throw new Error("Transaction no longer exists");
  if (row.is_child) throw new Error("Open the whole split to edit its parts.");
  if (row.is_parent && !wholeSplit) throw new Error("Save split transactions with their parts.");
  if (row.reconciled && !allowReconciled)
    throw new Error("This transaction was reconciled after you opened it. Close it and open it again to review your change.");
  const linked = row.transfer_id ? await find(row.transfer_id) : undefined;
  // Actual would carry an edit to the split's child, unbalancing the split or
  // moving the child away from its parent's account.
  if (linked?.is_child)
    throw new Error("This transfer is linked to part of a split transaction. Edit it in Actual for now.");
  if (linked?.reconciled && !allowReconciledTransfer)
    throw new Error(
      "The linked transaction in the other account was reconciled after you opened this transfer. Close it and open it again to review your change.",
    );
  return row;
}
async function perform(method: string, args: Obj): Promise<unknown> {
  await start();
  if (
    [
      "saveTransaction", "deleteTransaction", "budget", "sync", "syncAccounts", "setCleared",
      "unlockTransaction", "createReconciliationTransaction", "finishReconciliation", "saveTargets",
      "applyTargets", "budgetAction", "saveSplit", "commitImport", ...managementMethods, ...scheduleWrites, ...ruleWrites,
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
    case "reportsDashboard":
      return runMutator(dashboard);
    case "report":
      return runMutator(() => report(text(args.id), object(args.options ?? {})));
    case "reportTransactions":
      return runMutator(() => reportTransactions(text(args.id), text(args.date)));
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
    case "loginMethods": {
      const url = await serverURL(args.url);
      const server = await lib.send("subscribe-needs-bootstrap", { url });
      if ("error" in server)
        throw new Error(server.error === "network-failure" ? unreachable : "This address did not respond like an Actual server.");
      if (!server.bootstrapped) throw new Error("Finish setting up this server in Actual first.");
      // Like Actual's login screen, offer the server's methods, its active one first.
      const methods = (server.availableLoginMethods ?? [])
        .filter((m) => m.method === "password" || m.method === "openid")
        .sort((a, b) => Number(b.active) - Number(a.active))
        .map((m) => m.method);
      if (!methods.length) throw new Error("This server uses a sign-in method this app does not support.");
      // The first person to sign in with OpenID becomes the server owner.
      let ownerCreated = true;
      if (methods.includes("openid")) {
        try {
          ownerCreated = (await withServer(url, () => lib.send("owner-created"))) === true;
        } catch {
          throw new Error(unreachable);
        }
      }
      return { methods, ownerCreated };
    }
    case "openIdSignIn": {
      // Returns the provider's page. After sign-in, the server sends a session
      // token to returnUrl; Actual accepts return addresses on localhost.
      const url = await serverURL(args.url);
      const password = text(args.password);
      const result = await withServer(url, () =>
        lib.send("subscribe-sign-in", { loginMethod: "openid", returnUrl: text(args.returnUrl), password }),
      );
      if ("error" in result && result.error) throw new Error(openIdError(result.error, password));
      if (!("redirectUrl" in result) || typeof result.redirectUrl !== "string")
        throw new Error("Your server did not start OpenID sign-in. Try again.");
      return { url: result.redirectUrl };
    }
    case "connect": {
      const url = await serverURL(args.url);
      const oldURL = await storage.getItem("server-url");
      const oldToken = await storage.getItem("user-token");
      setServer(url);
      try {
        if (args.token !== undefined) await useSessionToken(text(args.token));
        else
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
    case "budgetAction":
      await budgetAction(args.month, text(args.action), object(args.args ?? {}));
      return {};
    case "categoryTargets":
      return runMutator(() => categoryTargets(text(args.categoryId), text(args.month)));
    case "previewTargets":
      return runMutator(() => previewTargets(text(args.categoryId), text(args.month), args.templates));
    case "saveTargets":
      await saveTargets(text(args.categoryId), args.templates);
      return {};
    case "applyTargets":
      return applyTargets(text(args.month), text(args.categoryId) || null, args.overwrite === true);
    case "saveTransaction": {
      const id = text(args.id);
      const existing = id
        ? await editable(id, args.allowReconciled === true, args.allowReconciledTransfer === true)
        : null;
      const accountId = text(args.accountId),
        date = text(args.date);
      if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new Error("Choose a valid date.");
      const accounts = await lib.send("accounts-get");
      const account = accounts.find((a) => a.id === accountId);
      if (!account) throw new Error("This account no longer exists. Choose another account.");
      const payees = await lib.send("api/payees-get");
      let payee = text(args.payeeId) || null;
      const name = text(args.payeeName).trim();
      const transferAccountId = text(args.transferAccountId);
      if (transferAccountId) {
        // As in Actual, the other account's payee makes this a transfer.
        payee = payees.find((p) => p.transfer_acct === transferAccountId)?.id ?? null;
        if (!payee) throw new Error("The account to transfer with no longer exists. Choose another account.");
      } else if (!payee && name) {
        // Like Actual, reuse an existing payee whose name differs only in case.
        payee = await runMutator(() => createPayee(name));
      }
      const transferTarget = payees.find((p) => p.id === payee)?.transfer_acct;
      if (transferTarget === accountId) throw new Error("Choose two different accounts for a transfer.");
      const other = accounts.find((a) => a.id === transferTarget);
      const fields = {
        account: accountId,
        date,
        payee,
        // Actual never categorizes off-budget transactions, or transfers
        // between two on-budget accounts.
        category: account.offbudget || (other && !other.offbudget) ? null : text(args.categoryId) || null,
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
        // The app may choose the ID, so it can show the transaction before it is saved.
        const newId = text(args.newId);
        if (newId && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(newId))
          throw new Error("Invalid transaction ID");
        const draft = {
          id: newId || crypto.randomUUID(),
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
    case "saveSplit":
      await saveSplit(args);
      return {};
    case "deleteTransaction": {
      const id = text(args.id);
      // Deleting a split deletes its parts too.
      await editable(id, args.allowReconciled === true, args.allowReconciledTransfer === true, true);
      // Actual deletes a transfer's linked transaction too.
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
    case "deleteBudget": {
      // Like Actual's "Delete file locally": a server budget stays on the server.
      const id = text(args.id);
      if (!(await budgets()).some((budget) => budget.id === id))
        throw new Error("This budget is no longer on this device.");
      // Actual deletes from its file list, with no budget open. Its handler
      // opens the budget's database, which would replace an open one.
      if (getPrefs()?.id) await lib.send("close-budget");
      if ((await storage.getItem("native-last-budget")) === id) await storage.removeItem("native-last-budget");
      if ((await lib.send("delete-budget", { id })) !== "ok")
        throw new Error("The budget could not be deleted. Try again.");
      await storage.removeItem("native-dropped-sync:" + id);
      return { budgets: await budgets() };
    }
    default:
      if ([...managementMethods, "categoryNeedsTransfer", "payees", "tags"].includes(method)) {
        if (!getPrefs()?.id) throw new Error("Open a budget first.");
        return manage(method, args);
      }
      if (method === "schedules") return runMutator(schedules);
      if (method === "schedulePreviews") return runMutator(schedulePreviews);
      if (method === "rules") return runMutator(rulesList);
      if (method === "prepareImport" || method === "commitImport") {
        if (!getPrefs()?.id) throw new Error("Open a budget first.");
        return method === "prepareImport" ? prepareImport(args) : commitImport(args);
      }
      if ([...ruleWrites, "ruleMatches"].includes(method)) {
        if (!getPrefs()?.id) throw new Error("Open a budget first.");
        return ruleCommand(method, args);
      }
      if ([...scheduleWrites, "upcomingDates", "scheduleTransactions"].includes(method)) {
        if (!getPrefs()?.id) throw new Error("Open a budget first.");
        return scheduleCommand(method, args);
      }
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
    if (["bootstrap", "open", "download", "demo", "close", "deleteBudget", "connect", "loginMethods", "openIdSignIn"].includes(method)) {
      // A sync must finish against the budget/server with which it started.
      await activeSync?.catch(() => {});
    }
    reply(await execute(method, args));
  }).catch(reject);
}
