// Category, group, account, and notes management, as Actual's mobile budget
// and account menus do it. Updates send the whole entity, as desktop-client's
// save mutations do, so upstream validation sees every required field.
import { lib } from "@actual/core";
import { integerToAmount } from "@actual/source/shared/util.ts";

type Obj = Record<string, unknown>;

function text(value: unknown): string {
  return typeof value === "string" ? value : "";
}
function name(value: unknown, what: string): string {
  const trimmed = text(value).trim();
  if (!trimmed) throw new Error(`Enter a name for the ${what}.`);
  return trimmed;
}

async function categories() {
  return (await lib.send("get-categories", {})).list;
}
async function groups() {
  return lib.send("get-category-groups", {});
}
async function findCategory(id: unknown) {
  const found = (await categories()).find((c) => c.id === id);
  if (!found) throw new Error("This category no longer exists.");
  return found;
}
async function findGroup(id: unknown) {
  const found = (await groups()).find((g) => g.id === id);
  if (!found) throw new Error("This category group no longer exists.");
  return found;
}
async function accounts() {
  return lib.send("accounts-get");
}
async function findAccount(id: unknown) {
  const found = (await accounts()).find((a) => a.id === id);
  if (!found) throw new Error("This account no longer exists.");
  return found;
}
// Like desktop-client's validateAccountName: required, and unique among accounts.
async function accountName(value: unknown, id: string): Promise<string> {
  const trimmed = text(value).trim();
  if (!trimmed) throw new Error("Name cannot be blank.");
  if ((await accounts()).some((a) => a.name === trimmed && a.id !== id))
    throw new Error(`Name ${trimmed} already exists.`);
  return trimmed;
}
// Actual's delete dialogs ask for a category to receive the deleted one's
// transactions and budgets. It must be of the same kind, and not being deleted.
async function transferCategory(value: unknown, isIncome: boolean, excluded: Set<string>) {
  if (value == null || value === "") return null;
  const target = await findCategory(value);
  if (excluded.has(target.id)) throw new Error("Choose a category that is not being deleted.");
  if (Boolean(target.is_income) !== isIncome)
    throw new Error(isIncome ? "Choose an income category." : "Choose an expense category.");
  return target.id;
}

export async function manage(method: string, args: Obj): Promise<unknown> {
  switch (method) {
    case "createCategoryGroup":
      return { id: await lib.send("category-group-create", { name: name(args.name, "group") }) };
    case "updateCategoryGroup": {
      const { categories: _categories, ...group } = await findGroup(args.id);
      await lib.send("category-group-update", {
        ...group,
        ...(args.name !== undefined && { name: name(args.name, "group") }),
        ...(typeof args.hidden === "boolean" && { hidden: args.hidden }),
      });
      return {};
    }
    case "deleteCategoryGroup": {
      const group = await findGroup(args.id);
      const ids = new Set((group.categories ?? []).map((c) => c.id));
      // As in Actual, a transfer is required when any category has transactions or budgets.
      let required = false;
      for (const id of ids) if (await lib.send("must-category-transfer", { id })) required = true;
      const transferId = await transferCategory(args.transferId, Boolean(group.is_income), ids);
      if (required && !transferId)
        throw new Error("Choose a category to receive this group’s transactions and budgets.");
      await lib.send("category-group-delete", { id: group.id, transferId });
      return {};
    }
    case "createCategory": {
      const group = await findGroup(args.groupId);
      const id = await lib.send("category-create", {
        name: name(args.name, "category"),
        groupId: group.id,
        isIncome: Boolean(group.is_income),
        hidden: false,
      });
      return { id };
    }
    case "updateCategory": {
      const category = await findCategory(args.id);
      const next = { ...category };
      if (args.name !== undefined) next.name = name(args.name, "category");
      if (typeof args.hidden === "boolean") next.hidden = args.hidden;
      if (args.groupId !== undefined) {
        const group = await findGroup(args.groupId);
        if (Boolean(group.is_income) !== Boolean(category.is_income))
          throw new Error("Move income categories only to income groups.");
        next.group = group.id;
      }
      // Actual keeps names unique within a group.
      if (
        (await categories()).some(
          (c) => c.id !== next.id && c.group === next.group && c.name.toUpperCase() === next.name.toUpperCase(),
        )
      )
        throw new Error(`A category with the name "${next.name}" already exists in this group.`);
      if (next.group !== category.group) await lib.send("category-move", { id: next.id, groupId: next.group, targetId: null });
      await lib.send("category-update", next);
      return {};
    }
    case "categoryNeedsTransfer": {
      const category = await findCategory(args.id);
      return { required: Boolean(await lib.send("must-category-transfer", { id: category.id })) };
    }
    case "deleteCategory": {
      const category = await findCategory(args.id);
      const required = await lib.send("must-category-transfer", { id: category.id });
      const transferId = await transferCategory(args.transferId, Boolean(category.is_income), new Set([category.id]));
      if (required && !transferId)
        throw new Error("Choose a category to receive this category’s transactions and budgets.");
      await lib.send("category-delete", { id: category.id, transferId });
      return {};
    }
    case "moveCategory": {
      // Reorders within a group: before targetId, or last when it is null.
      const category = await findCategory(args.id);
      const targetId = text(args.targetId) || null;
      if (targetId && (await findCategory(targetId)).group !== category.group)
        throw new Error("Move a category within its group.");
      await lib.send("category-move", { id: category.id, groupId: category.group, targetId });
      return {};
    }
    case "moveCategoryGroup": {
      const group = await findGroup(args.id);
      const targetId = text(args.targetId) || null;
      if (targetId) await findGroup(targetId);
      await lib.send("category-group-move", { id: group.id, targetId });
      return {};
    }
    case "saveNotes": {
      // Notes belong to a category, group, account, or month (budget-YYYY-MM).
      const id = text(args.id);
      if (!id) throw new Error("Choose what these notes are for.");
      await lib.send("notes-save", { id, note: text(args.note) });
      return {};
    }
    case "createAccount": {
      const balance = args.balance ?? 0;
      if (typeof balance !== "number" || !Number.isSafeInteger(balance)) throw new Error("Enter a valid balance.");
      const id = await lib.send("account-create", {
        name: await accountName(args.name, ""),
        // Actual's create handler takes the balance as a decimal amount.
        balance: integerToAmount(balance),
        offBudget: args.offBudget === true,
      });
      return { id };
    }
    case "updateAccount": {
      const account = await findAccount(args.id);
      await lib.send("account-update", { id: account.id, name: await accountName(args.name, account.id) });
      return {};
    }
    case "closeAccount": {
      const account = await findAccount(args.id);
      if (account.closed) throw new Error("This account is already closed.");
      if (args.forced === true) {
        await lib.send("account-close", { id: account.id, forced: true });
        return {};
      }
      const { balance } = await lib.send("account-properties", { id: account.id });
      const transferAccountId = text(args.transferAccountId) || undefined;
      let categoryId: string | undefined;
      if (balance !== 0) {
        // As in Actual's close dialog, a balance moves to another open account.
        if (!transferAccountId) throw new Error("Choose an account to receive this account’s balance.");
        const target = await findAccount(transferAccountId);
        if (target.id === account.id || target.closed) throw new Error("Choose another open account.");
        // From on budget to off budget, the transfer leaves the budget and needs a category.
        if (!account.offbudget && target.offbudget) {
          categoryId = text(args.categoryId) || undefined;
          if (!categoryId) throw new Error("Choose a category for the transfer out of your budget.");
          if ((await findCategory(categoryId)).is_income) throw new Error("Choose an expense category.");
        }
      }
      await lib.send("account-close", { id: account.id, transferAccountId, categoryId });
      return {};
    }
    case "reopenAccount": {
      const account = await findAccount(args.id);
      await lib.send("account-reopen", { id: account.id });
      return {};
    }
    case "payees": {
      // As Actual's payees page: ordinary payees, how many rules use each, and which are unused.
      const payees = (await lib.send("payees-get")).filter((p) => !p.transfer_acct);
      const counts = await lib.send("payees-get-rule-counts");
      const unused = new Set((await lib.send("payees-get-orphaned")).map((p) => p.id));
      return payees
        .map((p) => ({
          id: p.id,
          name: p.name,
          ruleCount: (counts as Record<string, number>)[p.id] ?? 0,
          unused: unused.has(p.id),
        }))
        .sort((a, b) => a.name.localeCompare(b.name));
    }
    case "renamePayee": {
      const payee = await ordinaryPayee(args.id);
      await lib.send("payees-batch-change", { updated: [{ id: payee.id, name: name(args.name, "payee") }] });
      return {};
    }
    case "deletePayees": {
      const ids = await payeeIds(args.ids);
      await lib.send("payees-batch-change", { deleted: ids.map((id) => ({ id })) });
      return {};
    }
    case "mergePayees": {
      // The merged payees' transactions and rules move to the target, as in Actual.
      const target = await ordinaryPayee(args.targetId);
      const ids = (await payeeIds(args.mergeIds)).filter((id) => id !== target.id);
      if (!ids.length) throw new Error("Choose payees to merge into another.");
      await lib.send("payees-merge", { targetId: target.id, mergeIds: ids });
      return {};
    }
    default:
      throw new Error("Unknown operation: " + method);
  }
}

// Transfer payees stand for accounts, which Actual never renames, merges, or deletes as payees.
async function ordinaryPayee(id: unknown) {
  const payee = (await lib.send("payees-get")).find((p) => p.id === id);
  if (!payee) throw new Error("This payee no longer exists.");
  if (payee.transfer_acct) throw new Error("Transfer payees belong to accounts and can’t be changed here.");
  return payee;
}
async function payeeIds(value: unknown): Promise<string[]> {
  if (!Array.isArray(value) || !value.length) throw new Error("Choose at least one payee.");
  const ids: string[] = [];
  for (const id of value) ids.push((await ordinaryPayee(id)).id);
  return ids;
}

export const managementMethods = [
  "createCategoryGroup", "updateCategoryGroup", "deleteCategoryGroup", "createCategory", "updateCategory",
  "deleteCategory", "moveCategory", "moveCategoryGroup", "saveNotes", "createAccount", "updateAccount",
  "closeAccount", "reopenAccount", "renamePayee", "deletePayees", "mergePayees",
];
