import { lib } from "@actual/core";
import type { SyncResponseWithErrors } from "@actual/source/server/accounts/app.ts";
import type { AccountEntity } from "@actual/source/types/models/account.ts";
import * as storage from "@actual/storage";

export function canSyncBank(account: AccountEntity): boolean {
  return Boolean(account.bank && !account.closed && !account.tombstone);
}

type AccountResult = {
  accountId: string;
  added: number;
  updated: number;
  error: string | null;
};

function errorMessage(error: SyncResponseWithErrors["errors"][number]): string {
  if ("type" in error && error.type === "SyncError") {
    if (
      error.code === "ITEM_LOGIN_REQUIRED" || error.code === "INVALID_ACCESS_TOKEN" ||
      error.category === "INVALID_ACCESS_TOKEN"
    ) return "Reconnect this account in Actual web or desktop, then try again.";
    switch (error.category) {
      case "RATE_LIMIT_EXCEEDED": return "The bank's refresh limit was reached. Try again later.";
      case "ACCOUNT_NEEDS_ATTENTION": return "This account needs attention. Check its connection in Actual web or desktop.";
      case "ACCOUNT_MISSING": return "The bank did not return this account. Check its connection in Actual web or desktop.";
      case "TIMED_OUT": return "The bank took too long to respond. Try again later.";
      case "NO_DATA": return "The bank returned no data. Try again later.";
    }
  }
  switch (error.message) {
    case "unauthorized":
    case "token-expired": return "Reconnect to your Actual server in Settings, then try again.";
    case "network-failure": return "Could not reach your Actual server. Check your connection and try again.";
    default: return error.message;
  }
}

function result(accountId: string, response: SyncResponseWithErrors): AccountResult {
  return {
    accountId,
    added: response.newTransactions.length,
    updated: response.matchedTransactions.length,
    error: response.errors.length ? response.errors.map(errorMessage).join("\n") : null,
  };
}

function failed(accountId: string, message: string): AccountResult {
  return { accountId, added: 0, updated: 0, error: message };
}

export async function syncBankAccounts(accountId?: string) {
  const allAccounts = await lib.send("accounts-get");
  if (accountId && !allAccounts.some(account => account.id === accountId))
    throw new Error("This account no longer exists. Refresh the account list and try again.");
  const accounts = allAccounts.filter(account =>
    canSyncBank(account) && (!accountId || account.id === accountId),
  );
  // Both upstream handlers interpret [] as all accounts, never as no accounts.
  if (!accounts.length) return { accounts: [] };
  if (!(await storage.getItem("server-url")) || !(await storage.getItem("user-token")))
    throw new Error("Connect to your Actual server in Settings before refreshing bank accounts.");

  const results = new Map<string, AccountResult>();
  // accounts-get's bankId is the local bank row ID. accounts-bank-sync also
  // requires its external bank_id, otherwise it silently skips the account.
  // SimpleFIN's batch handler does not use it, and SimpleFIN may leave it empty.
  const banks = lib.db.runQuery<{ id: string }>(
    "SELECT id FROM banks WHERE bank_id IS NOT NULL AND bank_id != ''", [], true,
  );
  const bankIDs = new Set(banks.map(bank => bank.id));
  const linked = accounts.filter(account => {
    const bankLinked = account.account_sync_source === "simpleFin" || (account.bank && bankIDs.has(account.bank));
    if (account.account_id && account.bank && bankLinked && account.account_sync_source) return true;
    results.set(account.id, failed(account.id, "This bank connection is incomplete. Reconnect the account in Actual web or desktop."));
    return false;
  });
  const simpleFin = linked.filter(account => account.account_sync_source === "simpleFin");
  if (simpleFin.length) {
    try {
      const responses = await lib.send("simplefin-batch-sync", { ids: simpleFin.map(account => account.id) });
      for (const account of simpleFin) {
        const response = responses.find(response => response.accountId === account.id);
        results.set(account.id, response
          ? result(account.id, response.res)
          : failed(account.id, "The bank did not return a result for this account. Try again later."));
      }
    } catch {
      for (const account of simpleFin)
        results.set(account.id, failed(account.id, "Bank refresh could not finish. Check your connection and try again."));
    }
  }
  for (const account of linked.filter(account => account.account_sync_source !== "simpleFin")) {
    try {
      results.set(account.id, result(account.id, await lib.send("accounts-bank-sync", { ids: [account.id] })));
    } catch {
      results.set(account.id, failed(account.id, "Bank refresh could not finish. Check your connection and try again."));
    }
  }
  return { accounts: accounts.map(account => results.get(account.id) ??
    failed(account.id, "Bank refresh did not finish. Try again later.")) };
}
