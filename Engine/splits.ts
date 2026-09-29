// Split transactions, as Actual's mobile transaction editor saves them: a parent
// with the total, and children with their own amounts, categories, and notes.
// Built with loot-core's split helpers, then saved as the changes from what is
// stored, so fields other devices changed are kept.
import { lib } from "@actual/core";
import { createPayee } from "@actual/source/server/accounts/payees.ts";
import { runMutator } from "@actual/source/server/mutators.ts";
import { makeChild, recalculateSplit } from "@actual/source/shared/transactions.ts";

type Obj = Record<string, unknown>;
type Row = Obj & { id: string };

function text(value: unknown): string {
  return typeof value === "string" ? value : "";
}
function integer(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) throw new Error("Invalid monetary amount");
  return value;
}
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

async function rows(id: string): Promise<Row[]> {
  const { data } = await lib.send(
    "query",
    lib.q("transactions").filter({ $or: [{ id }, { parent_id: id }] }).select("*").options({ splits: "all" }).serialize(),
  );
  return data as Row[];
}

// The fields a split's parent and children store, compared to save only changes.
const parentFields = ["account", "date", "payee", "notes", "cleared", "amount", "category", "is_parent", "reconciled"];
const childFields = ["account", "date", "payee", "notes", "cleared", "amount", "category", "sort_order", "reconciled"];
const flags = new Set(["cleared", "reconciled", "is_parent"]);
// Stored values read back as null or 0/1; compare them as the app writes them.
function normalized(field: string, value: unknown) {
  if (flags.has(field)) return Boolean(value);
  if (field === "notes") return value || "";
  return value ?? null;
}
function changes(before: Row, after: Row, fields: string[]) {
  const changed: Obj = {};
  for (const field of fields)
    if (normalized(field, before[field]) !== normalized(field, after[field])) changed[field] = after[field];
  return changed;
}

export async function saveSplit(args: Obj): Promise<void> {
  const id = text(args.id);
  const existing = id ? await rows(id) : [];
  const parentBefore = existing.find((row) => row.id === id);
  if (id && !parentBefore) throw new Error("Transaction no longer exists");
  if (parentBefore?.is_child) throw new Error("Open the whole split to edit its parts.");
  const childrenBefore = existing.filter((row) => row.id !== id);
  // A split's parts can be transfers, but the whole split cannot.
  if (parentBefore?.transfer_id) throw new Error("This transaction is a transfer. Edit it in Actual for now.");
  const reconciled = Boolean(parentBefore?.reconciled);
  if (reconciled && args.allowReconciled !== true)
    throw new Error("This transaction was reconciled after you opened it. Close it and open it again to review your change.");

  const accountId = text(args.accountId);
  const date = text(args.date);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new Error("Choose a valid date.");
  const account = (await lib.send("accounts-get")).find((a) => a.id === accountId);
  if (!account) throw new Error("This account no longer exists. Choose another account.");
  let payee: string | null = text(args.payeeId) || null;
  const name = text(args.payeeName).trim();
  if (!payee && name) payee = await runMutator(() => createPayee(name));
  const payees = await lib.send("api/payees-get");
  if (payee && payees.find((p) => p.id === payee)?.transfer_acct)
    throw new Error("A split can’t be a transfer, but its parts can. Choose a payee.");
  const accounts = await lib.send("accounts-get");
  // Each part has its own payee or transfer, as Actual's split rows do, or the transaction's payee.
  async function partPayee(part: Obj): Promise<string | null> {
    const transferAccountId = text(part.transferAccountId);
    if (transferAccountId) {
      if (transferAccountId === accountId) throw new Error("Choose two different accounts for a transfer.");
      const transferPayee = payees.find((p) => p.transfer_acct === transferAccountId);
      if (!transferPayee) throw new Error("The account to transfer with no longer exists. Choose another account.");
      return transferPayee.id;
    }
    const partPayeeId = text(part.payeeId);
    if (partPayeeId) return partPayeeId;
    const partName = text(part.payeeName).trim();
    if (partName) return runMutator(() => createPayee(partName));
    return payee;
  }
  // As for any transfer, one between two on-budget accounts has no category.
  function budgetTransfer(part: Obj): boolean {
    const other = accounts.find((a) => a.id === text(part.transferAccountId));
    return Boolean(other && !other.offbudget && !account!.offbudget);
  }

  const categories = new Set(
    [...(await lib.send("api/categories-get", {})), ...(await lib.send("api/categories-get", { hidden: true }))].map(
      (c) => c.id,
    ),
  );
  // As in Actual, off-budget transactions have no category.
  function category(value: unknown): string | null {
    const categoryId = text(value) || null;
    if (!categoryId || account!.offbudget) return null;
    if (!categories.has(categoryId)) throw new Error("A category in this split no longer exists. Choose another.");
    return categoryId;
  }

  const parentId = id || text(args.newId) || crypto.randomUUID();
  if (!id && !uuid.test(parentId)) throw new Error("Invalid transaction ID");
  const amount = integer(args.amount);
  const parts = Array.isArray(args.splits) ? (args.splits as Obj[]) : [];
  // Moving a transaction to another account unlocks it, as in Actual's editors.
  const stillReconciled = reconciled && parentBefore?.account === accountId;
  const parent: Row = {
    id: parentId,
    account: accountId,
    date,
    payee,
    notes: text(args.notes),
    // A reconciled transaction stays cleared until it is unlocked.
    cleared: stillReconciled ? Boolean(parentBefore?.cleared) : Boolean(args.cleared),
    reconciled: stillReconciled,
    amount,
    category: parts.length ? null : category(args.categoryId),
    is_parent: parts.length > 0,
    sort_order: parentBefore?.sort_order ?? Date.now(),
  };
  const kept = new Set(childrenBefore.map((row) => row.id));
  const children: Row[] = [];
  for (const [index, part] of parts.entries()) {
    const childId = text(part.id);
    if (childId && !kept.has(childId)) throw new Error("A part of this split no longer exists. Close it and open it again.");
    if (!childId && part.id !== undefined && part.id !== null) throw new Error("Invalid split part");
    children.push(
      makeChild(parent as never, {
        ...(childId && { id: childId }),
        amount: integer(part.amount),
        category: budgetTransfer(part) ? null : category(part.categoryId),
        notes: text(part.notes),
        payee: await partPayee(part),
        sort_order: -(index + 1),
      }) as unknown as Row,
    );
  }
  if (parts.length) {
    const checked = recalculateSplit({ ...parent, subtransactions: children } as never) as { error: unknown };
    if (checked.error) throw new Error("The split amounts must add up to the total.");
  }

  const strip = (row: Row) => {
    const { error: _error, ...rest } = row;
    return rest as Row;
  };
  const added: Row[] = [];
  const updated: Obj[] = [];
  if (parentBefore) {
    const change = changes(parentBefore, parent, parentFields);
    if (Object.keys(change).length) updated.push({ id: parentId, ...change });
  } else added.push(strip(parent));
  for (const child of children) {
    const before = childrenBefore.find((row) => row.id === child.id);
    if (!before) added.push(strip(child));
    else {
      const change = changes(before, child, childFields);
      if (Object.keys(change).length) updated.push({ id: child.id, ...change });
    }
  }
  const remaining = new Set(children.map((child) => child.id));
  const deleted = childrenBefore.filter((row) => !remaining.has(row.id)).map((row) => ({ id: row.id }));
  if (added.length || updated.length || deleted.length)
    await lib.send("transactions-batch-update", { added, updated, deleted } as never);
}
