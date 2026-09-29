// Budget actions from Actual's mobile budget menus: month actions, a category's
// copy and averages, and moving money between categories, To Budget, and next
// month. Each runs the handler desktop-client's useBudgetActions sends.
import { lib } from "@actual/core";
import { getBudgetType } from "@actual/source/server/budget/base.ts";
import * as sheet from "@actual/source/server/sheet.ts";
import { sheetForMonth } from "@actual/source/shared/months.ts";

type Obj = Record<string, unknown>;

function month(value: unknown): string {
  if (typeof value !== "string" || !/^\d{4}-(0[1-9]|1[0-2])$/.test(value)) throw new Error("Invalid budget month");
  return value;
}
function positive(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0)
    throw new Error("Enter an amount greater than zero.");
  return value;
}
function cell(month: string, name: string): number {
  const value = sheet.getCellValue(sheetForMonth(month), name);
  return typeof value === "number" ? value : 0;
}
async function expenseCategory(value: unknown): Promise<string> {
  const id = typeof value === "string" ? value : "";
  const categories = await lib.send("api/categories-get", { hidden: true });
  const found = [...categories, ...(await lib.send("api/categories-get", {}))].find((c) => c.id === id);
  if (!found) throw new Error("This category no longer exists. Choose another category.");
  if (found.is_income) throw new Error("Choose an expense category.");
  return id;
}
// A category, or To Budget where the envelope menus offer it.
async function source(value: unknown, allowToBudget: boolean): Promise<string> {
  if (allowToBudget && value === "to-budget") return "to-budget";
  return expenseCategory(value);
}
function envelope() {
  if (getBudgetType() === "tracking") throw new Error("Moving money between categories is for envelope budgets.");
}
// Movement notes show amounts in the budget's currency, as Actual's menus pass it.
async function currencyCode(): Promise<string> {
  return (await lib.send("preferences/get")).defaultCurrencyCode || "";
}

export async function budgetAction(rawMonth: unknown, action: string, args: Obj): Promise<void> {
  const m = month(rawMonth);
  switch (action) {
    case "copy-last":
      await lib.send("budget/copy-previous-month", { month: m });
      return;
    case "set-zero":
      await lib.send("budget/set-zero", { month: m });
      return;
    case "set-3-avg":
      await lib.send("budget/set-3month-avg", { month: m });
      return;
    case "set-6-avg":
      await lib.send("budget/set-6month-avg", { month: m });
      return;
    case "set-12-avg":
      await lib.send("budget/set-12month-avg", { month: m });
      return;
    case "copy-single-last":
      await lib.send("budget/copy-single-month", { month: m, category: await expenseCategory(args.category) });
      return;
    case "set-single-avg": {
      const n = args.months;
      if (n !== 3 && n !== 6 && n !== 12) throw new Error("Choose 3, 6, or 12 months.");
      await lib.send("budget/set-n-month-avg", { month: m, N: n, category: await expenseCategory(args.category) });
      return;
    }
    case "carryover": {
      if (typeof args.flag !== "boolean") throw new Error("Choose whether to roll over overspending.");
      await lib.send("budget/set-carryover", {
        startMonth: m,
        category: await expenseCategory(args.category),
        flag: args.flag,
      });
      return;
    }
    case "transfer-category": {
      // From a category's balance to another category, or back to To Budget.
      envelope();
      const from = await expenseCategory(args.from);
      const to = await source(args.to, true);
      if (from === to) throw new Error("Choose a different category.");
      const amount = positive(args.amount);
      if (amount > cell(m, "leftover-" + from))
        throw new Error("This category does not have that much available.");
      await lib.send("budget/transfer-category", { month: m, amount, from, to, currencyCode: await currencyCode() });
      return;
    }
    case "cover-overspending": {
      // Actual covers no more than the source has available.
      envelope();
      const to = await expenseCategory(args.to);
      const from = await source(args.from, true);
      if (from === to) throw new Error("Choose a different category.");
      const amount = positive(args.amount);
      if (cell(m, from === "to-budget" ? "to-budget" : "leftover-" + from) <= 0)
        throw new Error(from === "to-budget" ? "There is nothing left to budget." : "That category has nothing available.");
      await lib.send("budget/cover-overspending", { month: m, to, from, amount, currencyCode: await currencyCode() });
      return;
    }
    case "transfer-available": {
      envelope();
      const category = await expenseCategory(args.category);
      const amount = positive(args.amount);
      if (cell(m, "to-budget") <= 0) throw new Error("There is nothing left to budget.");
      await lib.send("budget/transfer-available", { month: m, amount, category });
      return;
    }
    case "cover-overbudgeted": {
      envelope();
      const category = await expenseCategory(args.category);
      const amount = positive(args.amount);
      if (cell(m, "leftover-" + category) <= 0) throw new Error("That category has nothing available.");
      await lib.send("budget/cover-overbudgeted", { month: m, category, amount, currencyCode: await currencyCode() });
      return;
    }
    case "hold": {
      // As Actual's To Budget menu does, stop any automatic hold first.
      envelope();
      const amount = positive(args.amount);
      await lib.send("budget/reset-income-carryover", { month: m });
      if (!(await lib.send("budget/hold-for-next-month", { month: m, amount })))
        throw new Error("There is nothing left to budget to hold.");
      return;
    }
    case "reset-hold":
      envelope();
      await lib.send("budget/reset-hold", { month: m });
      return;
    case "disable-auto-hold":
      envelope();
      await lib.send("budget/reset-income-carryover", { month: m });
      return;
    default:
      throw new Error("Unknown budget action: " + action);
  }
}

// The envelope To Budget breakdown, as Actual's budget summary shows it.
export function envelopeSummary(m: string) {
  return {
    income: cell(m, "total-income"),
    fromLastMonth: cell(m, "from-last-month"),
    availableFunds: cell(m, "available-funds"),
    lastMonthOverspent: cell(m, "last-month-overspent"),
    budgeted: cell(m, "total-budgeted"),
    forNextMonth: cell(m, "buffered-selected"),
    manualHold: cell(m, "buffered"),
    autoHold: cell(m, "buffered-auto"),
  };
}
