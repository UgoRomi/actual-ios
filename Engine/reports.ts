// Reports dashboards and the widgets in Actual's default dashboard. The
// calculations are ported from desktop-client's reports/spreadsheets, which
// Actual runs in its client, and return exact integer minor units.
import { lib } from "@actual/core";
import { getBudgetType } from "@actual/source/server/budget/base.ts";
import * as months from "@actual/source/shared/months.ts";
import type { Query } from "@actual/source/shared/query.ts";
import type { Obj } from "./args";

type Mode =
  | "sliding-window"
  | "static"
  | "full"
  | "lastMonth"
  | "lastYear"
  | "yearToDate"
  | "priorYearToDate"
  | "currentQuarter"
  | "previousQuarter";
type TimeFrame = { start?: string; end?: string; mode?: Mode };
type Interval = "Daily" | "Weekly" | "Monthly" | "Yearly";
type Condition = Obj & { field?: unknown; op?: unknown; value?: unknown; customName?: unknown };

export function record(value: unknown): Obj {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Obj) : {};
}
export function text(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}
async function rows<T = Obj>(query: Query): Promise<T[]> {
  return (await lib.send("query", query.serialize())).data as T[];
}
async function total(query: Query): Promise<number> {
  const data = (await lib.send("query", query.serialize())).data;
  return typeof data === "number" ? data : 0;
}
async function syncedPrefs() {
  return (await lib.send("preferences/get")) as Obj;
}
async function firstDayOfWeek() {
  return text((await syncedPrefs()).firstDayOfWeekIdx) || "0";
}
export async function latestTransaction() {
  return (await lib.send("get-latest-transaction"))?.date ?? months.currentDay();
}

// Experimental widgets appear only when their feature flag is on, as in Overview.tsx.
const flagged: Record<string, string> = {
  "budget-analysis-card": "budgetAnalysisReport",
  "balance-forecast-card": "balanceForecastReport",
  "monte-carlo-card": "monteCarloReport",
  "formula-card": "formulaMode",
  "sankey-card": "sankeyReport",
};
const knownTypes = new Set([
  "net-worth-card",
  "cash-flow-card",
  "spending-card",
  "summary-card",
  "calendar-card",
  "markdown-card",
  "custom-report",
  "age-of-money-card",
  "crossover-card",
  ...Object.keys(flagged),
]);

// Dashboards in stored order, as ReportsDashboardRouter opens the first. Each
// page lists its widgets top to bottom, then left to right, as mobile web shows them.
export async function dashboard() {
  const prefs = await syncedPrefs();
  const pages = await rows<{ id: string; name: string | null }>(lib.q("dashboard_pages").select("*"));
  const widgets = await rows<{
    id: string;
    dashboard_page_id: string | null;
    type: string;
    x: number;
    y: number;
    meta: unknown;
  }>(lib.q("dashboard").select("*"));
  const reports = new Map(
    (await rows<{ id: string; name: string }>(lib.q("custom_reports").select(["id", "name"]))).map((r) => [
      r.id,
      r.name,
    ]),
  );
  const shown = widgets.filter(
    (w) => knownTypes.has(w.type) && (!flagged[w.type] || String(prefs["flags." + flagged[w.type]]) === "true"),
  );
  shown.sort((a, b) => a.y - b.y || a.x - b.x);
  const earliest = await lib.send("get-earliest-transaction");
  return {
    // Where "All time" starts.
    earliestMonth: earliest ? months.getMonth(earliest.date) : months.currentMonth(),
    pages: pages.map((page) => ({
      id: page.id,
      name: page.name ?? "",
      widgets: shown
        .filter((w) => w.dashboard_page_id === page.id)
        .map((w) => {
          const meta = record(w.meta);
          return {
            id: w.id,
            type: w.type,
            name: w.type === "custom-report" ? (reports.get(text(meta.id) ?? "") ?? null) : (text(meta.name) ?? null),
            // Text widgets carry their Markdown.
            content: w.type === "markdown-card" ? (text(meta.content) ?? "") : null,
            textAlign: w.type === "markdown-card" ? (text(meta.text_align) ?? "left") : null,
          };
        }),
    })),
  };
}

// reportRanges.ts calculateTimeRange: live ranges slide to the current month.
export function calculateTimeRange(
  timeFrame: TimeFrame | undefined,
  defaultTimeFrame: TimeFrame | undefined,
  latest: string,
): [string, string, Mode] {
  const start = timeFrame?.start ?? defaultTimeFrame?.start ?? months.subMonths(months.currentMonth(), 5);
  const end = timeFrame?.end ?? defaultTimeFrame?.end ?? months.currentMonth();
  const mode = timeFrame?.mode ?? defaultTimeFrame?.mode ?? "sliding-window";
  const current = months.currentMonth();
  switch (mode) {
    case "full": {
      const latestMonth = latest ? months.monthFromDate(latest) : null;
      return [start, latestMonth && months.isAfter(latestMonth, current) ? latestMonth : current, "full"];
    }
    case "sliding-window": {
      // Day-shaped ranges slide by days: same width, ending today.
      if (months.isValidYearMonthDay(start) && months.isValidYearMonthDay(end)) {
        const dayOffset = months.differenceInCalendarDays(end, start);
        const today = months.currentDay();
        return [months.subDays(today, Math.max(dayOffset, 0)), today, "sliding-window"];
      }
      const offset = months.differenceInCalendarMonths(end, start);
      if (start > end) return [current, months.subMonths(current, -offset), "sliding-window"];
      return [months.subMonths(current, offset), current, "sliding-window"];
    }
    case "lastMonth": {
      const last = months.subMonths(current, 1);
      return [last, last, "lastMonth"];
    }
    case "lastYear":
      return [
        months.getYearStart(months.prevYear(current)),
        months.getYearEnd(months.prevYear(months.currentDate())),
        "lastYear",
      ];
    case "yearToDate":
      return [months.currentYear() + "-01", current, "yearToDate"];
    case "priorYearToDate":
      return [
        months.getYearStart(months.prevYear(current)),
        months.prevYear(months.currentDate(), "yyyy-MM-dd"),
        "priorYearToDate",
      ];
    case "currentQuarter":
      return [months.getQuarterStart(current), months.getQuarterEnd(current), "currentQuarter"];
    case "previousQuarter": {
      const previous = months.prevQuarter(current);
      return [months.getQuarterStart(previous), months.getQuarterEnd(previous), "previousQuarter"];
    }
    default:
      return [start, end, "static"];
  }
}

export const modes = new Set<string>([
  "sliding-window",
  "static",
  "full",
  "lastMonth",
  "lastYear",
  "yearToDate",
  "priorYearToDate",
  "currentQuarter",
  "previousQuarter",
]);
export const datePattern = /^\d{4}-(0[1-9]|1[0-2])(-(0[1-9]|[12]\d|3[01]))?$/;
export function timeFrame(value: unknown): TimeFrame | undefined {
  const raw = record(value);
  if (!Object.keys(raw).length) return undefined;
  const start = text(raw.start), end = text(raw.end), mode = text(raw.mode);
  return {
    start: start && datePattern.test(start) ? start : undefined,
    end: end && datePattern.test(end) ? end : undefined,
    mode: mode && modes.has(mode) ? (mode as Mode) : undefined,
  };
}

// Rule conditions from Actual's filter editor. Actual skips named (saved) filters here.
function conditions(value: unknown): Condition[] {
  return Array.isArray(value) ? value.map(record).filter((c) => !c.customName) : [];
}
async function filters(meta: Obj, key = "conditions", opKey = "conditionsOp") {
  const { filters } = await lib.send("make-filters-from-conditions", {
    conditions: conditions(meta[key]) as never,
  });
  return { [meta[opKey] === "or" ? "$or" : "$and"]: filters };
}

export async function widget(id: string) {
  const [found] = await rows<{ type: string; meta: unknown }>(lib.q("dashboard").filter({ id }).select("*"));
  if (!found) throw new Error("This report is no longer on the dashboard. Refresh to see the current dashboard.");
  return { type: found.type, meta: record(found.meta) };
}

export function interval(value: unknown): Interval {
  return value === "Daily" || value === "Weekly" || value === "Yearly" ? value : "Monthly";
}

// net-worth-spreadsheet.ts
type Balance = { date: string; amount: number };
type AccountBalances = { id: string; name: string; balances: Record<string, Balance>; starting: number };
type TransferLeg = { id: string; account: string; amount: number; date: string; transfer_id: string };

async function netWorth(meta: Obj, override: Obj) {
  const [start, end] = calculateTimeRange(timeFrame(override.timeFrame) ?? timeFrame(meta.timeFrame), undefined, await latestTransaction());
  const every = interval(override.interval ?? meta.interval);
  const weekStart = await firstDayOfWeek();
  const where = await filters(meta);
  const accounts = (await lib.send("accounts-get")) as Array<{ id: string; name: string }>;

  // Go back one interval before the range to get the first period's starting balance.
  const rangeStart = months.firstDayOfMonth(start);
  let startDate =
    every === "Daily"
      ? months.subDays(rangeStart, 1)
      : every === "Weekly"
        ? months.weekFromDate(months.subDays(rangeStart, 1), weekStart)
        : months.firstDayOfMonth(months.prevMonth(start));
  // With no earlier transactions, that lookback would only add an empty point.
  const earliest = await lib.send("get-earliest-transaction");
  if (earliest && earliest.date >= rangeStart) {
    startDate =
      every === "Daily"
        ? earliest.date
        : every === "Weekly"
          ? months.weekFromDate(earliest.date, weekStart)
          : rangeStart;
  }
  let endDate = months.lastDayOfMonth(end);
  if ((every === "Daily" || every === "Weekly") && months.isAfter(endDate, months.currentDay()))
    endDate = months.currentDay();

  const ids = accounts.map((a) => a.id);
  const group = every === "Yearly" ? { $year: "$date" } : every === "Monthly" ? { $month: "$date" } : "date";
  const data: AccountBalances[] = [];
  for (const account of accounts) {
    const starting = await total(
      lib.q("transactions").filter({ ...where, account: account.id, date: { $lt: startDate } }).calculate({ $sum: "$amount" }),
    );
    const sums = await rows<Balance>(
      lib
        .q("transactions")
        .filter(where)
        .filter({ account: account.id, $and: [{ date: { $gte: startDate } }, { date: { $lte: endDate } }] })
        .groupBy(group)
        .select([{ date: group }, { amount: { $sum: "$amount" } }]),
    );
    const balances: Record<string, Balance> = {};
    for (const sum of sums) {
      const key = every === "Weekly" ? months.weekFromDate(sum.date, weekStart) : sum.date;
      balances[key] = { date: key, amount: (balances[key]?.amount ?? 0) + sum.amount };
    }
    data.push({ id: account.id, name: account.name, balances, starting });
  }
  if (ids.length) {
    const legFields = ["id", "account", "amount", "date", "transfer_id"];
    let legs = await rows<TransferLeg>(
      lib
        .q("transactions")
        .filter(where)
        .filter({ account: { $oneof: ids }, transfer_id: { $ne: null }, date: { $lte: endDate } })
        .select(legFields),
    );
    const loaded = new Set(legs.map((leg) => leg.id));
    const missing = [...new Set(legs.map((leg) => leg.transfer_id).filter((id) => !loaded.has(id)))];
    if (missing.length)
      legs = legs.concat(
        await rows<TransferLeg>(
          lib
            .q("transactions")
            .filter(where)
            .filter({ id: { $oneof: missing }, account: { $oneof: ids }, transfer_id: { $ne: null } })
            .select(legFields),
        ),
      );
    // Paired internal transfers must not change net worth between their two dates.
    alignTransfers(data, legs, startDate, endDate, every, weekStart);
  }

  const intervals =
    every === "Weekly"
      ? months.weekRangeInclusive(startDate, endDate, weekStart)
      : every === "Daily"
        ? months.dayRangeInclusive(startDate, endDate)
        : every === "Yearly"
          ? months.yearRangeInclusive(startDate, endDate)
          : months.rangeInclusive(months.getMonth(startDate), months.getMonth(endDate));
  const running = data.map((account) => {
    let balance = account.starting;
    return intervals.map((key) => (balance += account.balances[key]?.amount ?? 0));
  });
  const points = intervals.map((key, index) => {
    let assets = 0, debt = 0;
    const balances: Record<string, number> = {};
    running.forEach((values, i) => {
      const balance = values[index];
      balances[data[i].id] = balance;
      if (balance < 0) debt += -balance;
      else assets += balance;
    });
    return { date: key, total: assets - debt, assets, debt, balances };
  });
  const first = points[0]?.total ?? 0, last = points.at(-1)?.total ?? 0;
  return {
    start,
    end,
    interval: every,
    mode: meta.mode === "stacked" ? "stacked" : "trend",
    netWorth: last,
    totalChange: last - first,
    points,
    accounts: data.filter((_, i) => running[i].some((b) => b !== 0)).map((a) => ({ id: a.id, name: a.name })),
  };
}

function intervalKey(date: string, every: Interval, weekStart: string) {
  if (every === "Daily") return date;
  if (every === "Weekly") return months.weekFromDate(date, weekStart);
  if (every === "Yearly") return date.slice(0, 4);
  return months.getMonth(date);
}

function alignTransfers(
  data: AccountBalances[],
  legs: TransferLeg[],
  startDate: string,
  endDate: string,
  every: Interval,
  weekStart: string,
) {
  const accountsById = new Map(data.map((account) => [account.id, account]));
  const legsById = new Map(legs.map((leg) => [leg.id, leg]));
  const processed = new Set<string>();
  for (const leg of legs) {
    if (processed.has(leg.id)) continue;
    const other = legsById.get(leg.transfer_id);
    if (
      !other ||
      other.transfer_id !== leg.id ||
      other.account === leg.account ||
      other.amount + leg.amount !== 0 ||
      !accountsById.has(leg.account) ||
      !accountsById.has(other.account)
    )
      continue;
    processed.add(leg.id);
    processed.add(other.id);
    if (leg.date === other.date) continue;
    const [earlier, later] = leg.date < other.date ? [leg, other] : [other, leg];
    const account = accountsById.get(earlier.account);
    if (!account || later.date < startDate) continue;
    // Move the earlier leg to the later leg's date.
    if (earlier.date < startDate) account.starting -= earlier.amount;
    else {
      if (earlier.date > endDate) continue;
      const original = account.balances[intervalKey(earlier.date, every, weekStart)];
      if (!original) continue;
      original.amount -= earlier.amount;
    }
    if (later.date > endDate) continue;
    const key = intervalKey(later.date, every, weekStart);
    const balance = account.balances[key];
    if (balance) balance.amount += earlier.amount;
    else account.balances[key] = { date: key, amount: earlier.amount };
  }
}

// CashFlow.tsx: the whole current month; the query clamps to today.
export function cashFlowDefault(): TimeFrame {
  return { start: months.currentMonth(), end: months.currentMonth(), mode: "sliding-window" };
}

// cash-flow-spreadsheet.ts simpleCashFlow: the card's income and expenses.
async function cashFlowTotals(meta: Obj, start: string, end: string) {
  const where = await filters(meta);
  const first = months.firstDayOfMonth(start);
  const last = months.lastDayOfMonth(end);
  const query = () =>
    lib
      .q("transactions")
      .filter(where)
      .filter({
        $and: [{ date: { $gte: first } }, { date: { $lte: last > months.currentDay() ? months.currentDay() : last } }],
        "account.offbudget": false,
        "payee.transfer_acct": null,
      })
      .calculate({ $sum: "$amount" });
  return {
    income: await total(query().filter({ amount: { $gt: 0 } })),
    expense: await total(query().filter({ amount: { $lt: 0 } })),
  };
}

// cash-flow-spreadsheet.ts cashFlowByDate: the detail page, by day or, over three months, by month.
async function cashFlowByDate(meta: Obj, startMonth: string, endMonth: string) {
  const isConcise = months.differenceInCalendarDays(endMonth, startMonth) > 31 * 3;
  const where = await filters(meta);
  const start = months.firstDayOfMonth(startMonth);
  const end = months.lastDayOfMonth(endMonth);
  const fixedEnd = end > months.currentDay() ? months.currentDay() : end;
  type Row = { date: string; isTransfer: string | null; amount: number };
  const query = () => {
    const base = lib
      .q("transactions")
      .filter(where)
      .filter({
        $and: [{ date: { $transform: "$month", $gte: start } }, { date: { $transform: "$month", $lte: fixedEnd } }],
        "account.offbudget": false,
      });
    return isConcise
      ? base
          .groupBy([{ $month: "$date" }, "payee.transfer_acct"])
          .select([{ date: { $month: "$date" } }, { isTransfer: "payee.transfer_acct" }, { amount: { $sum: "$amount" } }])
      : base
          .groupBy(["date", "payee.transfer_acct"])
          .select(["date", { isTransfer: "payee.transfer_acct" }, { amount: { $sum: "$amount" } }]);
  };
  const starting = await total(
    lib
      .q("transactions")
      .filter({ ...where, date: { $transform: "$month", $lt: start }, "account.offbudget": false })
      .calculate({ $sum: "$amount" }),
  );
  // util.ts indexCashFlow: amounts by date, split into transfers and the rest.
  const index = (list: Row[]) => {
    const result: Record<string, { transfers: number; other: number }> = {};
    for (const row of list) {
      const entry = (result[row.date] ??= { transfers: 0, other: 0 });
      if (row.isTransfer !== null) entry.transfers += row.amount;
      else entry.other += row.amount;
    }
    return result;
  };
  const incomes = index(await rows<Row>(query().filter({ amount: { $gt: 0 } })));
  const expenses = index(await rows<Row>(query().filter({ amount: { $lt: 0 } })));
  const dates = isConcise
    ? months.rangeInclusive(months.getMonth(start), months.getMonth(fixedEnd))
    : months.dayRangeInclusive(start, fixedEnd);
  let balance = starting, totalIncome = 0, totalExpenses = 0, totalTransfers = 0;
  const points = dates.map((date) => {
    const income = incomes[date]?.other ?? 0, expense = expenses[date]?.other ?? 0;
    const transfers = (incomes[date]?.transfers ?? 0) + (expenses[date]?.transfers ?? 0);
    totalIncome += income;
    totalExpenses += expense;
    totalTransfers += transfers;
    balance += income + expense + transfers;
    return { date, income, expense, transfers, balance };
  });
  return {
    isConcise,
    points,
    balance: points.at(-1)?.balance ?? starting,
    totalIncome,
    totalExpenses,
    totalTransfers,
    totalChange: (points.at(-1)?.balance ?? 0) - (points[0]?.balance ?? 0),
  };
}

async function cashFlow(meta: Obj, override: Obj) {
  const [start, end] = calculateTimeRange(
    timeFrame(override.timeFrame) ?? timeFrame(meta.timeFrame),
    cashFlowDefault(),
    await latestTransaction(),
  );
  return {
    start,
    end,
    showBalance: meta.showBalance !== false,
    ...(await cashFlowTotals(meta, start, end)),
    detail: override.detail === true ? await cashFlowByDate(meta, start, end) : null,
  };
}

// spendingAverageRange.ts
export function averageRange(value: unknown) {
  const raw = record(value);
  if (raw.mode === "last-n-months" && [3, 6, 12].includes(Number(raw.months)))
    return { mode: "last-n-months", months: Number(raw.months) } as const;
  if (raw.mode === "year-to-date" || raw.mode === "all-time") return { mode: raw.mode } as const;
  return { mode: "last-n-months", months: 3 } as const;
}

// reportRanges.ts calculateSpendingReportTimeRange
function spendingRange(meta: Obj): [string, string] {
  const compare = text(meta.compare);
  const compareTo = text(meta.compareTo);
  const isLive = meta.isLive !== false;
  const mode = text(meta.mode) ?? "single-month";
  if ((mode === "budget" || mode === "average") && isLive) {
    const month = compare ?? months.currentMonth();
    return [month, month];
  }
  if (mode === "single-month" && isLive && compare) return [compare, compareTo ?? months.subMonths(compare, 1)];
  const [start, end] = calculateTimeRange(
    { start: compare, end: compareTo, mode: isLive ? "sliding-window" : "static" },
    { start: months.currentMonth(), end: months.subMonths(months.currentMonth(), 1), mode: "sliding-window" },
    "",
  );
  return [start, end];
}

// budgetDataQuery.ts: which categories a budget comparison may include.
function supportedCategoryCondition(c: Condition) {
  if (c.field !== "category" && c.field !== "category_group") return false;
  if (c.op === "is" || c.op === "isNot") return typeof c.value === "string";
  if (c.op === "oneOf" || c.op === "notOneOf")
    return Array.isArray(c.value) && c.value.every((id) => typeof id === "string");
  if (c.op === "contains" || c.op === "doesNotContain" || c.op === "matches") return typeof c.value === "string";
  return false;
}
async function spendingBudgetFilters(list: Condition[], op: unknown) {
  const budgetConditions = list.filter((c) => c.field === "category" || c.field === "category_group");
  if (!budgetConditions.length || !budgetConditions.every(supportedCategoryCondition)) return [];
  const { list: categories, grouped } = await lib.send("get-categories");
  const groupNames = new Map(grouped.map((g) => [g.id, g.name]));
  const matches = (category: { id: string; name: string; group?: string }, c: Condition) => {
    const key = c.field === "category_group" ? (category.group ?? "") : category.id;
    const name = c.field === "category_group" ? (groupNames.get(key) ?? key) : category.name;
    const value = c.value;
    switch (c.op) {
      case "is":
        return key === value;
      case "isNot":
        return key !== value;
      case "oneOf":
        return Array.isArray(value) && value.includes(key);
      case "notOneOf":
        return Array.isArray(value) && !value.includes(key);
      case "contains":
        return typeof value === "string" && name.toLowerCase().includes(value.toLowerCase());
      case "doesNotContain":
        return typeof value === "string" && !name.toLowerCase().includes(value.toLowerCase());
      case "matches":
        if (typeof value !== "string" || value.length > 256) return true;
        try {
          return new RegExp(value, "i").test(name);
        } catch {
          return false;
        }
      default:
        return true;
    }
  };
  const ids = categories
    .filter((category) =>
      op === "or"
        ? budgetConditions.some((c) => matches(category, c))
        : budgetConditions.every((c) => matches(category, c)),
    )
    .map((category) => category.id);
  return [{ category: { $oneof: ids } }];
}

// spending-spreadsheet.ts createSpendingSpreadsheet
async function spending(meta: Obj) {
  const [compare, compareTo] = spendingRange(meta);
  const range = averageRange(meta.averageRange);
  const endDate = months.getMonthEnd(compare + "-01");
  const startDateTo = compareTo + "-01";
  const endDateTo = months.getMonthEnd(compareTo + "-01");
  const compareDays = months.dayRangeInclusive(compare + "-01", endDate);

  // The months averaged: before the compared month, as far back as the range asks.
  const averageEnd = months.subMonths(compare, 1);
  let averageStart: string | null =
    range.mode === "last-n-months"
      ? months.subMonths(compare, range.months)
      : range.mode === "year-to-date"
        ? `${months.getYear(compare)}-01`
        : null;
  if (range.mode === "all-time") {
    const earliest = await lib.send("get-earliest-transaction");
    averageStart = earliest ? months.monthFromDate(earliest.date.slice(0, 7)) : null;
  }
  const averageMonths = new Set(
    averageStart && averageStart <= averageEnd ? months.rangeInclusive(averageStart, averageEnd) : [],
  );
  const startDate = (averageMonths.size ? averageStart : compare) + "-01";

  const where = await filters(meta);
  type Row = { date: string; amount: number; categoryIncome: boolean | number | null; accountOffBudget: boolean | number | null };
  // makeQuery.ts, by day.
  const query = (name: "assets" | "debts", from: string, to: string) =>
    lib
      .q("transactions")
      .filter(where)
      .filter({ $and: [{ date: { $transform: "$day", $gte: from } }, { date: { $transform: "$day", $lte: to } }] })
      .filter(name === "assets" ? { amount: { $gt: 0 } } : { amount: { $lt: 0 } })
      .groupBy([{ $day: "$date" }, { $id: "$account" }, { $id: "$payee" }, { $id: "$category" }, { $id: "$payee.transfer_acct.id" }])
      .select([
        { date: { $day: "$date" } },
        { categoryIncome: { $id: "$category.is_income" } },
        { accountOffBudget: { $id: "$account.offbudget" } },
        { amount: { $sum: "$amount" } },
      ]);
  const separate = endDateTo < startDate || startDateTo > endDate;
  const assets = [
    ...(await rows<Row>(query("assets", startDate, endDate))),
    ...(separate ? await rows<Row>(query("assets", startDateTo, endDateTo)) : []),
  ];
  const debts = [
    ...(await rows<Row>(query("debts", startDate, endDate))),
    ...(separate ? await rows<Row>(query("debts", startDateTo, endDateTo)) : []),
  ];
  const byDate = new Map<string, number>();
  for (const row of [...assets, ...debts])
    if (!row.categoryIncome && !row.accountOffBudget) byDate.set(row.date, (byDate.get(row.date) ?? 0) + row.amount);

  const budgetConditions = conditions(meta.conditions);
  const budgetFilters = budgetConditions.some((c) => c.field === "category" || c.field === "category_group")
    ? await spendingBudgetFilters(budgetConditions, meta.conditionsOp)
    : [];
  const budgets = await rows<{ amount: number }>(
    lib
      .q(getBudgetType() === "tracking" ? "reflect_budgets" : "zero_budgets")
      .filter({ $and: [{ month: { $eq: parseInt(compare.replace("-", "")) } }, ...budgetFilters] })
      .groupBy([{ $id: "$category" }])
      .select([{ category: { $id: "$category" } }, { amount: { $sum: "$amount" } }]),
  );
  const dailyBudget = budgets.reduce((sum, b) => sum + b.amount, 0) / compareDays.length;

  // Each month's cumulative spending by day of month. Days 28 and later count as the 28th.
  const monthList = months.rangeInclusive(startDate, endDate);
  if (separate) monthList.unshift(compareTo);
  const cumulative = new Map(monthList.map((m) => [m, 0]));
  let budget = 0;
  const today = months.currentDay();
  // Each month's dates, bucketed by day of month.
  const buckets = new Map(monthList.map((month) => {
    const byDay: string[][] = Array.from({ length: 28 }, () => []);
    for (const date of months.dayRangeInclusive(month + "-01", months.getMonthEnd(month + "-01")))
      byDay[Math.min(Number(date.slice(8, 10)), 28) - 1].push(date);
    return [month, byDay] as const;
  }));
  const days = [];
  for (let day = 1; day <= 28; day++) {
    let averageSum = 0, averageCount = 0;
    const values = new Map<string, number | null>();
    for (const month of monthList) {
      let value: number | null = null;
      for (const date of buckets.get(month)![day - 1]) {
        const spent = (cumulative.get(month) ?? 0) + (byDate.get(date) ?? 0);
        cumulative.set(month, spent);
        if (month === compare) budget -= dailyBudget;
        // A month's 28th point averages only its full total, on its last day.
        if (averageMonths.has(month) && (day < 28 || months.getMonthEnd(date) === date)) {
          averageSum += spent;
          averageCount += 1;
        }
        if (date <= today) value = spent;
      }
      values.set(month, value);
    }
    days.push({
      day,
      compare: values.get(compare) ?? null,
      compareTo: values.get(compareTo) ?? null,
      budget: Math.round(budget),
      average: averageCount === 0 ? 0 : Math.round(averageSum / averageCount),
    });
  }
  // SpendingCard: the difference on today's day of month, or the 28th for other months.
  const todayIndex = compare !== months.currentMonth() ? 27 : Math.min(months.getDay(today) - 1, 27);
  const mode = meta.mode === "budget" || meta.mode === "average" ? meta.mode : "single-month";
  return {
    compare,
    compareTo,
    mode,
    averageRange: range,
    averageMonths: averageMonths.size,
    todayIndex,
    days,
  };
}

// Summary.tsx and Calendar.tsx: without a saved range, this month on.
export function monthToDateDefault(): TimeFrame {
  return { start: months.dayFromDate(months.currentMonth()), end: months.currentDay(), mode: "full" };
}
// A summary widget keeps its options as JSON in meta.content.
export function summaryContent(meta: Obj): Obj {
  try {
    if (typeof meta.content === "string") return record(JSON.parse(meta.content));
  } catch {}
  return { type: "sum" };
}
export const summaryTypes = ["sum", "avgPerMonth", "avgPerYear", "avgPerTransact", "percentage"];
export function summaryType(content: Obj): string {
  return summaryTypes.includes(String(content.type)) ? String(content.type) : "sum";
}

// summary-spreadsheet.ts
async function summary(meta: Obj, override: Obj) {
  const [start, end] = calculateTimeRange(
    timeFrame(override.timeFrame) ?? timeFrame(meta.timeFrame),
    monthToDateDefault(),
    await latestTransaction(),
  );
  const content = summaryContent(meta);
  const type = summaryType(content);
  const startDay = months.firstDayOfMonth(start);
  const endDay =
    months.getMonth(end) === months.getMonth(months.currentDay()) ? months.currentDay() : months.lastDayOfMonth(end);
  if (startDay > endDay) throw new Error("Start date must be before or equal to end date.");
  const where = await filters(meta);
  let query = lib
    .q("transactions")
    .filter({ $and: [{ date: { $gte: startDay } }, { date: { $lte: endDay } }] })
    .filter(where)
    .select(["date", { amount: { $sum: "$amount" } }, { count: { $count: "*" } }]);
  if (type === "avgPerMonth" || type === "avgPerYear") query = query.groupBy(["date"]);
  const data = await rows<{ date: string; amount: number; count: number }>(query);
  const sum = data.reduce((acc, row) => acc + (row.amount ?? 0), 0);
  let result = { total: 0, dividend: 0, divisor: 0 };
  switch (type) {
    case "sum":
      result = { total: data[0]?.amount ?? 0, dividend: data[0]?.amount ?? 0, divisor: 0 };
      break;
    case "avgPerTransact": {
      const count = data[0]?.count ?? 0;
      result = { total: count ? (data[0]?.amount ?? 0) / count : 0, dividend: data[0]?.amount ?? 0, divisor: count };
      break;
    }
    case "avgPerMonth": {
      if (!data.length) break;
      // Whole months, and the elapsed share of the last one.
      const count = months.rangeInclusive(months.getMonth(startDay), months.getMonth(endDay)).length;
      const share = months.getDay(endDay) / months.getDay(months.lastDayOfMonth(endDay));
      // Upstream sums only the months in range; the query holds no others.
      const numMonths = count - 1 + share;
      result = { total: sum / numMonths, dividend: sum, divisor: numMonths };
      break;
    }
    case "avgPerYear": {
      if (!data.length) break;
      const numYears = (months.differenceInCalendarDays(endDay, startDay) + 1) / 365.25;
      result = { total: sum / numYears, dividend: sum, divisor: numYears };
      break;
    }
    case "percentage": {
      const divisorWhere = await filters(content, "divisorConditions", "divisorConditionsOp");
      let divisorQuery = lib.q("transactions").filter(divisorWhere).select([{ amount: { $sum: "$amount" } }]);
      if (!content.divisorAllTimeDateRange)
        divisorQuery = divisorQuery.filter({ $and: [{ date: { $gte: startDay } }, { date: { $lte: endDay } }] });
      const divisor = (await rows<{ amount: number }>(divisorQuery))[0]?.amount ?? 0;
      result = { total: Math.round((sum / divisor) * 10000) / 100, dividend: sum, divisor };
      break;
    }
  }
  return {
    start: startDay,
    end: endDay,
    type,
    // Actual shows averages rounded to whole minor units, and percentages with two decimals.
    total: type === "percentage" ? (Number.isFinite(result.total) ? result.total : null) : Math.round(result.total),
    dividend: Math.round(result.dividend),
    divisor: result.divisor,
    divisorAllTime: type === "percentage" && Boolean(content.divisorAllTimeDateRange),
  };
}

// calendar-spreadsheet.ts: income and expenses per day of each month in range.
async function calendar(meta: Obj, override: Obj) {
  const [start, end] = calculateTimeRange(
    timeFrame(override.timeFrame) ?? timeFrame(meta.timeFrame),
    monthToDateDefault(),
    await latestTransaction(),
  );
  const startDay = months.firstDayOfMonth(start);
  const endDay = months.lastDayOfMonth(end);
  const where = await filters(meta);
  const query = () =>
    lib
      .q("transactions")
      .filter({ $and: [{ date: { $gte: startDay } }, { date: { $lte: endDay } }] })
      .filter(where)
      .groupBy(["date"])
      .select(["date", { amount: { $sum: "$amount" } }]);
  const expenses = await rows<Balance>(query().filter({ $and: { amount: { $lt: 0 } } }));
  const incomes = await rows<Balance>(query().filter({ $and: { amount: { $gt: 0 } } }));
  const byDay = new Map<string, { date: string; income: number; expense: number }>();
  for (const row of incomes) byDay.set(row.date, { date: row.date, income: row.amount, expense: 0 });
  for (const row of expenses) {
    const entry = byDay.get(row.date) ?? { date: row.date, income: 0, expense: 0 };
    entry.expense = -row.amount;
    byDay.set(row.date, entry);
  }
  const days = [...byDay.values()].sort((a, b) => a.date.localeCompare(b.date));
  return {
    start: startDay,
    end: endDay,
    firstDayOfWeekIdx: Number(await firstDayOfWeek()) || 0,
    months: months.rangeInclusive(months.getMonth(startDay), months.getMonth(endDay)).map((month) => {
      const inMonth = days.filter((day) => day.date.startsWith(month));
      return {
        month,
        totalIncome: inMonth.reduce((sum, day) => sum + day.income, 0),
        totalExpense: inMonth.reduce((sum, day) => sum + day.expense, 0),
        days: inMonth,
      };
    }),
  };
}

export async function report(id: string, override: Obj) {
  const { type, meta } = await widget(id);
  switch (type) {
    case "net-worth-card":
      return { type, netWorth: await netWorth(meta, override) };
    case "cash-flow-card":
      return { type, cashFlow: await cashFlow(meta, override) };
    case "spending-card":
      return { type, spending: await spending(meta) };
    case "summary-card":
      return { type, summary: await summary(meta, override) };
    case "calendar-card":
      return { type, calendar: await calendar(meta, override) };
    default:
      throw new Error("Open this report in Actual web or desktop.");
  }
}

// Calendar.tsx: the transactions a calendar widget counts on one day.
export async function reportTransactions(id: string, date: string) {
  if (!months.isValidYearMonthDay(date)) throw new Error("Choose a valid date.");
  const { type, meta } = await widget(id);
  if (type !== "calendar-card") throw new Error("Only calendar reports list transactions.");
  const where = await filters(meta);
  const found = await rows<{
    id: string;
    date: string;
    amount: number;
    notes: string | null;
    account: string;
    payee: string | null;
    category: string | null;
    is_parent: boolean;
  }>(lib.q("transactions").filter(where).filter({ date }).select("*").options({ splits: "grouped" }));
  const payees = new Map((await lib.send("api/payees-get")).map((p) => [p.id, p]));
  const accounts = new Map(((await lib.send("accounts-get")) as Array<{ id: string; name: string }>).map((a) => [a.id, a.name]));
  const categories = new Map(
    [...(await lib.send("api/categories-get", {})), ...(await lib.send("api/categories-get", { hidden: true }))].map(
      (c) => [c.id, c.name],
    ),
  );
  return found.map((row) => {
    const payee = row.payee ? payees.get(row.payee) : undefined;
    const other = payee?.transfer_acct ? accounts.get(payee.transfer_acct) : undefined;
    return {
      id: row.id,
      date: row.date,
      amount: row.amount,
      accountName: accounts.get(row.account) ?? "",
      payeeName: other ? (row.amount > 0 ? "Transfer from " : "Transfer to ") + other : (payee?.name ?? null),
      categoryName: row.is_parent ? "Split" : row.category ? (categories.get(row.category) ?? null) : null,
      notes: row.notes || "",
    };
  });
}
