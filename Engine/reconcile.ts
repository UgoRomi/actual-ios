// Reconciliation, ported from desktop-client's accounts/reconciliation.ts,
// which Actual runs in its client rather than as engine handlers.
import { lib } from "@actual/core";
import { currentDay } from "@actual/source/shared/months.ts";
import {
  realizeTempTransactions,
  ungroupTransactions,
  updateTransaction,
} from "@actual/source/shared/transactions.ts";
import { applyChanges } from "@actual/source/shared/util.ts";
import type { TransactionEntity } from "@actual/source/types/models/transaction.ts";

// Splits are read grouped, so that updateTransaction carries a parent's
// cleared and reconciled state to its children.
async function grouped(filter: Record<string, unknown>): Promise<TransactionEntity[]> {
  const { data } = await lib.send(
    "query",
    lib.q("transactions").filter(filter).select("*").options({ splits: "grouped" }).serialize(),
  );
  return ungroupTransactions(data as TransactionEntity[]);
}

async function account(accountId: string) {
  const found = (await lib.send("accounts-get")).find((a) => a.id === accountId);
  if (!found) throw new Error("This account no longer exists. Refresh the account list and try again.");
  return found;
}

// The same query as Actual's cleared-balance binding.
export async function clearedBalance(accountId: string): Promise<number> {
  const { data } = await lib.send(
    "query",
    lib.q("transactions")
      .filter({ cleared: true, account: accountId })
      .options({ splits: "none" })
      .calculate({ $sum: "$amount" })
      .serialize(),
  );
  return typeof data === "number" ? data : 0;
}

async function transaction(id: string) {
  const transactions = await grouped({ id });
  const found = transactions.find((t) => t.id === id);
  if (!found) throw new Error("Transaction no longer exists");
  return { transactions, found };
}

// Like the cleared toggle while reconciling on mobile, but with an explicit
// value, so a repeated tap on an outdated row cannot undo itself.
export async function setCleared(id: string, cleared: boolean) {
  const { transactions, found } = await transaction(id);
  if (found.is_child) throw new Error("Clear the whole split transaction instead.");
  if (found.reconciled)
    throw new Error("Unlock this reconciled transaction before changing whether it is cleared.");
  if (Boolean(found.cleared) === cleared) return;
  const { diff } = updateTransaction(transactions, { ...found, cleared });
  await lib.send("transactions-batch-update", diff);
}

export async function unlockTransaction(id: string) {
  const { transactions, found } = await transaction(id);
  if (!found.reconciled) return;
  const { diff } = updateTransaction(transactions, { ...found, reconciled: false });
  await lib.send("transactions-batch-update", { updated: diff.updated });
}

async function lockTransactions(accountId: string) {
  let transactions = await grouped({ cleared: true, reconciled: false, account: accountId });
  const updated: Array<Partial<TransactionEntity>> = [];
  for (const trans of [...transactions]) {
    const { diff } = updateTransaction(transactions, { ...trans, reconciled: true });
    // Keep the list current, so later split members see earlier updates.
    transactions = applyChanges(diff, transactions);
    updated.push(...diff.updated);
  }
  await lib.send("transactions-batch-update", { updated });
}

// Actual computes the difference in its client from the balance on screen.
// Compute it here instead, so a change synced meanwhile cannot unbalance it.
export async function createReconciliationTransaction(accountId: string, targetBalance: number) {
  await account(accountId);
  const difference = targetBalance - (await clearedBalance(accountId));
  if (difference === 0) return;
  const transactions = realizeTempTransactions([
    {
      id: "temp",
      account: accountId,
      cleared: true,
      reconciled: false,
      amount: difference,
      date: currentDay(),
      notes: "Reconciliation balance adjustment",
    },
  ]);
  const ruled = await Promise.all(
    transactions.map((transaction) => lib.send("rules-run", { transaction })),
  );
  await lib.send("transactions-batch-update", {
    added: ruled.filter((t) => !t.tombstone),
    deleted: ruled.filter((t) => t.tombstone),
  });
}

// Like Actual, lock cleared transactions only if they match the bank balance,
// and record the reconciliation time either way. A lock the user asked for
// fails instead if the balance changed after it was shown.
export async function finishReconciliation(accountId: string, targetBalance: number, lock: boolean) {
  await account(accountId);
  const balanced = (await clearedBalance(accountId)) === targetBalance;
  if (lock && !balanced)
    throw new Error("The cleared balance changed, so nothing was locked. Review it and try again.");
  if (balanced) await lockTransactions(accountId);
  await lib.send("account-update", { id: accountId, last_reconciled: String(Date.now()) });
}
