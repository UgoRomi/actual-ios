// Editing dashboard widgets. Actual's report pages and card menus save a widget by
// rewriting its meta through dashboard-update-widget; so does this. A save carries
// only the settings that changed, merged into the widget as it is now.
import { lib } from "@actual/core";
import * as months from "@actual/source/shared/months.ts";
import { getFieldError } from "@actual/source/shared/rules.ts";
import { object, type Obj } from "./args";
import {
  averageRange,
  calculateTimeRange,
  cashFlowDefault,
  datePattern,
  interval,
  latestTransaction,
  modes,
  monthToDateDefault,
  record,
  summaryContent,
  summaryType,
  summaryTypes,
  text,
  timeFrame,
  widget,
} from "./reports";

const common = ["name", "conditions", "conditionsOp"];
// The settings each kind of widget saves, as its page in Actual does.
const settings: Record<string, string[]> = {
  "net-worth-card": [...common, "timeFrame", "interval", "graphMode"],
  "cash-flow-card": [...common, "timeFrame", "showBalance"],
  "spending-card": [...common, "compare", "compareTo", "spendingMode", "averageRange"],
  "summary-card": [
    ...common,
    "timeFrame",
    "summaryType",
    "divisorConditions",
    "divisorConditionsOp",
    "divisorAllTimeDateRange",
  ],
  "calendar-card": [...common, "timeFrame"],
  "markdown-card": ["content", "textAlign"],
};
// What Actual names a widget whose name is cleared.
const defaultNames: Record<string, string> = {
  "net-worth-card": "Net Worth",
  "cash-flow-card": "Cash Flow",
  "spending-card": "Monthly Spending",
  "summary-card": "Summary",
  "calendar-card": "Calendar",
};
const notEditable = "Edit this widget in Actual web or desktop.";

function op(value: unknown) {
  return value === "or" ? "or" : "and";
}
function list(value: unknown): Obj[] {
  return Array.isArray(value) ? value.map(record) : [];
}
function savedMonth(value: unknown): string | null {
  return typeof value === "string" && months.isValidYearMonth(value) ? value : null;
}
function spendingMode(value: unknown) {
  return value === "budget" || value === "average" ? value : "single-month";
}
function align(value: unknown) {
  return value === "center" || value === "right" ? value : "left";
}

// A widget's settings with Actual's defaults filled in, as its page opens with them.
export async function reportSettings(id: string) {
  const { type, meta } = await widget(id);
  if (!settings[type]) throw new Error(notEditable);
  if (type === "markdown-card")
    return {
      id,
      type,
      name: "",
      conditions: [],
      conditionsOp: "and",
      content: text(meta.content) ?? "",
      textAlign: align(meta.text_align),
    };
  const range = async (fallback?: ReturnType<typeof timeFrame>) => {
    const [start, end, mode] = calculateTimeRange(timeFrame(meta.timeFrame), fallback, await latestTransaction());
    return { start, end, mode };
  };
  const base = {
    id,
    type,
    name: text(meta.name) ?? "",
    conditions: list(meta.conditions),
    conditionsOp: op(meta.conditionsOp),
  };
  switch (type) {
    case "net-worth-card":
      return {
        ...base,
        timeFrame: await range(),
        interval: interval(meta.interval),
        graphMode: meta.mode === "stacked" ? "stacked" : "trend",
      };
    case "cash-flow-card":
      return { ...base, timeFrame: await range(cashFlowDefault()), showBalance: meta.showBalance !== false };
    case "spending-card":
      return {
        ...base,
        // Without saved months, the widget compares the current month with the one before.
        compare: savedMonth(meta.compare),
        compareTo: savedMonth(meta.compareTo),
        spendingMode: spendingMode(meta.mode),
        averageRange: averageRange(meta.averageRange),
      };
    case "summary-card": {
      const content = summaryContent(meta);
      return {
        ...base,
        timeFrame: await range(monthToDateDefault()),
        summaryType: summaryType(content),
        divisorConditions: list(content.divisorConditions),
        divisorConditionsOp: op(content.divisorConditionsOp),
        divisorAllTimeDateRange: Boolean(content.divisorAllTimeDateRange),
      };
    }
    default:
      return { ...base, timeFrame: await range(monthToDateDefault()) };
  }
}

function choice<T extends string>(value: unknown, options: readonly T[], message: string): T {
  if (typeof value === "string" && (options as readonly string[]).includes(value)) return value as T;
  throw new Error(message);
}
function flag(value: unknown): boolean {
  if (typeof value !== "boolean") throw new Error("Choose on or off.");
  return value;
}

// Filters as Actual's filter menu saves them. Each must be one Actual can run;
// named filters pass through, as Actual keeps but does not run them here.
async function savedConditions(value: unknown, what: string): Promise<Obj[]> {
  if (!Array.isArray(value)) throw new Error("Choose valid filters.");
  const conditions = value.map(record);
  for (const [index, condition] of conditions.entries()) {
    if (condition.customName) continue;
    const { errors } = (await lib.send("make-filters-from-conditions", { conditions: [condition] } as never)) as {
      errors?: string[];
    };
    if (errors?.length)
      throw new Error(
        `${what} ${index + 1}: ${errors[0] === "internal" ? "This filter is not valid." : getFieldError(errors[0])}`,
      );
  }
  return conditions;
}

// A range as Actual's page holds it after choosing it: evaluated once, so a live
// range is saved ending this month.
async function savedTimeFrame(value: unknown) {
  const raw = record(value);
  const start = text(raw.start), end = text(raw.end), mode = text(raw.mode);
  if (!start || !end || !mode || !datePattern.test(start) || !datePattern.test(end) || !modes.has(mode))
    throw new Error("Choose a valid range.");
  const first = start.length === 7 ? start + "-01" : start;
  const last = end.length === 7 ? months.lastDayOfMonth(end) : end;
  if (mode === "static" && first > last) throw new Error("The range must start before it ends.");
  const [from, to, kind] = calculateTimeRange(timeFrame(raw), undefined, await latestTransaction());
  return { start: from, end: to, mode: kind };
}

function savedAverageRange(value: unknown) {
  const raw = record(value);
  if (raw.mode === "last-n-months" && [3, 6, 12].includes(Number(raw.months)))
    return { mode: "last-n-months", months: Number(raw.months) };
  if (raw.mode === "year-to-date" || raw.mode === "all-time") return { mode: raw.mode };
  throw new Error("Choose a valid average.");
}

export async function saveReportWidget(args: Obj) {
  const id = text(args.id) ?? "";
  const changes = object(args.changes);
  const { type, meta } = await widget(id);
  const allowed = settings[type];
  if (!allowed) throw new Error(notEditable);
  const next: Obj = { ...meta };
  // Summary options live together in meta.content; others there, such as the font size, stay.
  let content: Obj | null = null;
  const summary = () => (content ??= { ...summaryContent(meta) });
  for (const [key, value] of Object.entries(changes)) {
    if (!allowed.includes(key)) throw new Error("This widget has no setting named " + key + ".");
    switch (key) {
      case "name":
        next.name = (text(value) ?? "").trim() || defaultNames[type];
        break;
      case "conditions":
        next.conditions = await savedConditions(value, "Filter");
        break;
      case "conditionsOp":
        next.conditionsOp = choice(value, ["and", "or"], "Choose all or any.");
        break;
      case "timeFrame":
        next.timeFrame = await savedTimeFrame(value);
        break;
      case "interval":
        next.interval = choice(value, ["Daily", "Weekly", "Monthly", "Yearly"], "Choose a valid interval.");
        break;
      case "graphMode":
        next.mode = choice(value, ["trend", "stacked"], "Choose a valid graph.");
        break;
      case "showBalance":
        next.showBalance = flag(value);
        break;
      case "compare":
      case "compareTo":
        // Null returns to the current month, or to the month before the compared one.
        if (value === null) delete next[key];
        else if (savedMonth(value)) next[key] = value;
        else throw new Error("Choose a valid month.");
        break;
      case "spendingMode":
        next.mode = choice(value, ["single-month", "budget", "average"], "Choose a valid comparison.");
        break;
      case "averageRange":
        next.averageRange = savedAverageRange(value);
        break;
      case "summaryType":
        summary().type = choice(value, summaryTypes, "Choose a valid summary.");
        break;
      case "divisorConditions":
        summary().divisorConditions = await savedConditions(value, "Divisor filter");
        break;
      case "divisorConditionsOp":
        summary().divisorConditionsOp = choice(value, ["and", "or"], "Choose all or any.");
        break;
      case "divisorAllTimeDateRange":
        summary().divisorAllTimeDateRange = flag(value);
        break;
      case "content":
        if (typeof value !== "string") throw new Error("Enter the widget’s text.");
        next.content = value;
        break;
      case "textAlign":
        next.text_align = choice(value, ["left", "center", "right"], "Choose a valid alignment.");
        break;
    }
  }
  if (content) {
    // Summary.tsx always saves the divisor's filters with the content.
    const saved: Obj = content;
    saved.divisorConditions = list(saved.divisorConditions);
    saved.divisorConditionsOp = op(saved.divisorConditionsOp);
    next.content = JSON.stringify(saved);
  }
  await lib.send("dashboard-update-widget", { id, meta: next } as never);
  return {};
}

export const reportWrites = ["saveReportWidget"];
