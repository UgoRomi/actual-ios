// Category targets, which Actual calls budget automations or goal templates.
// Reading, validation, and migration are ported from desktop-client's
// BudgetAutomationsModal and budget/goals, which Actual runs in its client.
import { lib } from "@actual/core";
import { parse } from "@actual/source/server/budget/goal-template.pegjs";
import {
  getActiveSchedules,
  getCategoriesWithTemplateNotes,
} from "@actual/source/server/budget/statements.ts";
import type { TemplateNotification } from "@actual/source/server/budget/template-notification.ts";
import { getDecimalPlaces } from "@actual/source/shared/currencies.ts";
import * as months from "@actual/source/shared/months.ts";
import { amountToInteger, integerToAmount } from "@actual/source/shared/util.ts";
import type { Template } from "@actual/source/types/models/templates.ts";

type Obj = Record<string, unknown>;
// Active, named schedules that are not completed: the ones targets can cover.
type Schedule = { id: string; name: string };
const specialSources = ["all income", "available funds"];

async function decimalPlaces() {
  return getDecimalPlaces((await lib.send("preferences/get")).defaultCurrencyCode || "");
}

// Templates store decimal currency amounts; the app uses integer minor units.
function toNative(template: Template, places: number): Obj {
  const value: Obj = { ...template };
  if (typeof value.amount === "number") value.amount = amountToInteger(value.amount, places);
  if (value.adjustmentType === "fixed" && typeof value.adjustment === "number")
    value.adjustment = amountToInteger(value.adjustment, places);
  return value;
}

function number(value: unknown, name: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) throw new Error("Enter a valid " + name + ".");
  return value;
}
function whole(value: unknown, name: string): number {
  const result = number(value, name);
  if (!Number.isSafeInteger(result) || result < 1) throw new Error("Enter a valid " + name + ".");
  return result;
}
function money(value: unknown, places: number): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) throw new Error("Invalid monetary amount");
  return integerToAmount(value, places);
}
function day(value: unknown): string {
  if (typeof value !== "string" || !months.isValidYearMonthDay(value)) throw new Error("Choose a valid date.");
  return value;
}
// Validation reports a missing or invalid month.
function yearMonth(value: unknown): string {
  return typeof value === "string" ? value : "";
}
function priority(value: unknown): number {
  return Math.max(0, Math.round(number(value, "priority")));
}
function adjustment(raw: Obj, places: number) {
  if (raw.adjustmentType === "fixed")
    return { adjustmentType: "fixed", adjustment: money(raw.adjustment, places) } as const;
  if (raw.adjustmentType === "percent")
    return { adjustmentType: "percent", adjustment: number(raw.adjustment, "adjustment") } as const;
  return {};
}
function oneOf<T extends string>(value: unknown, options: readonly T[], name: string): T {
  if (typeof value !== "string" || !options.includes(value as T)) throw new Error("Choose a valid " + name + ".");
  return value as T;
}

// Rebuilds each template from the fields the web editor writes, so only
// well-formed templates reach Actual.
function fromNative(value: unknown, places: number): Template {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid target");
  const raw = value as Obj;
  const description = typeof raw.description === "string" && raw.description.trim() ? raw.description : undefined;
  const base = { directive: "template" as const, ...(description ? { description } : {}) };
  switch (raw.type) {
    case "periodic": {
      const period = (raw.period ?? {}) as Obj;
      return {
        ...base,
        type: "periodic",
        amount: money(raw.amount, places),
        period: {
          period: oneOf(period.period, ["day", "week", "month", "year"] as const, "period"),
          amount: whole(period.amount, "period"),
        },
        starting: day(raw.starting),
        priority: priority(raw.priority),
      };
    }
    case "by":
    case "spend": {
      const repeating = raw.annual != null || raw.repeat != null;
      const common = {
        ...base,
        amount: money(raw.amount, places),
        month: yearMonth(raw.month),
        priority: priority(raw.priority),
        ...(repeating ? { annual: raw.annual === true, repeat: whole(raw.repeat ?? 1, "repeat interval") } : {}),
      };
      return raw.type === "spend"
        ? { ...common, type: "spend", from: yearMonth(raw.from) }
        : { ...common, type: "by" };
    }
    case "percentage":
      return {
        ...base,
        type: "percentage",
        percent: number(raw.percent, "percentage"),
        previous: raw.previous === true,
        category: typeof raw.category === "string" ? raw.category : "",
        priority: priority(raw.priority),
      };
    case "schedule":
      return {
        ...base,
        type: "schedule",
        name: typeof raw.name === "string" ? raw.name : "",
        ...(typeof raw.scheduleId === "string" && raw.scheduleId ? { scheduleId: raw.scheduleId } : {}),
        ...(raw.full === true ? { full: true } : {}),
        ...adjustment(raw, places),
        priority: priority(raw.priority),
      };
    case "average":
      return {
        ...base,
        type: "average",
        numMonths: whole(raw.numMonths, "number of months"),
        ...adjustment(raw, places),
        priority: priority(raw.priority),
      };
    case "copy":
      return { ...base, type: "copy", lookBack: whole(raw.lookBack, "number of months"), priority: priority(raw.priority) };
    case "limit": {
      const period = oneOf(raw.period, ["daily", "weekly", "monthly"] as const, "period");
      return {
        ...base,
        type: "limit",
        amount: money(raw.amount, places),
        hold: raw.hold === true,
        period,
        ...(period === "weekly" ? { start: day(raw.start) } : {}),
        priority: null,
      };
    }
    case "refill":
      return { ...base, type: "refill", priority: priority(raw.priority) };
    case "remainder":
      return { ...base, type: "remainder", weight: whole(raw.weight, "weight"), priority: null };
    case "goal":
      return { ...(description ? { description } : {}), directive: "goal", type: "goal", amount: money(raw.amount, places) };
    default:
      throw new Error("This kind of target is not supported.");
  }
}

// template-notes.ts getCategoriesWithTemplates, without storing the result:
// the web editor does, but opening a category here must not change it.
async function noteTemplates(categoryId: string): Promise<{ note: string; templates: Template[] }> {
  const [category] = await getCategoriesWithTemplateNotes([categoryId]);
  if (!category?.note) return { note: "", templates: [] };
  const templates: Template[] = [];
  let descriptionLines: string[] = [];
  for (const line of category.note.split("\n")) {
    const trimmed = line.substring(line.indexOf("#")).trim();
    if (!trimmed.startsWith("#template") && !trimmed.startsWith("#goal")) {
      if (line.trim() === "" || trimmed.startsWith("#cleanup")) descriptionLines = [];
      else descriptionLines.push(line.trimEnd());
      continue;
    }
    const description = descriptionLines.length ? descriptionLines.join("\n") : undefined;
    descriptionLines = [];
    let template: Template;
    try {
      template = parse(trimmed);
      if (
        (template.type === "average" || template.type === "schedule") &&
        template.adjustmentType === "percent" &&
        template.adjustment !== undefined &&
        (template.adjustment <= -100 || template.adjustment > 1000)
      )
        throw new Error(
          `Invalid adjustment percentage (${template.adjustment}%). Must be between -100% and 1000%`,
        );
    } catch (error) {
      template = { type: "error", directive: "error", line, error: (error as Error).message };
    }
    templates.push(description ? { ...template, description } : template);
  }
  return { note: category.note, templates };
}

// migrateTemplatesToAutomations: the web editor's form of legacy templates.
function migrate(templates: Template[], schedules: Schedule[]): Template[] {
  const result: Template[] = [];
  for (const template of templates) {
    if (template.type === "schedule") {
      const schedule = template.scheduleId
        ? schedules.find((s) => s.id === template.scheduleId)
        : template.name
          ? schedules.find((s) => s.name.trim() === template.name?.trim())
          : undefined;
      result.push(schedule ? { ...template, scheduleId: schedule.id, name: schedule.name } : template);
    } else if (template.type === "simple") {
      const { monthly, description } = template;
      const hasMonthly = monthly != null && monthly !== 0;
      if (template.limit) {
        result.push({
          type: "limit",
          amount: template.limit.amount,
          hold: template.limit.hold,
          period: template.limit.period,
          start: template.limit.start,
          directive: "template",
          priority: null,
          ...(description && !hasMonthly ? { description } : {}),
        });
        if (monthly == null) result.push({ type: "refill", directive: "template", priority: template.priority });
      }
      const contribution = hasMonthly || (monthly === 0 && template.limit == null) ? monthly : null;
      if (contribution != null)
        result.push({
          type: "periodic",
          amount: contribution,
          period: { period: "month", amount: 1 },
          starting: months.dayFromDate(months.firstDayOfMonth(months.currentDate())),
          directive: "template",
          priority: template.priority,
          ...(description ? { description } : {}),
        });
    } else if ((template.type === "periodic" || template.type === "remainder") && template.limit) {
      const { limit, ...rest } = template;
      result.push(rest as Template, {
        type: "limit",
        amount: limit.amount,
        hold: limit.hold,
        period: limit.period,
        start: limit.start,
        directive: "template",
        priority: null,
      });
    } else result.push(template);
  }
  return result;
}

type Context = { schedules: Schedule[]; income: { id: string; name: string }[] };
async function context(): Promise<Context> {
  const schedules = (await getActiveSchedules())
    .filter((s) => s.name && !s.completed)
    .map((s) => ({ id: s.id, name: s.name ?? "" }))
    .sort((a, b) => a.name.localeCompare(b.name));
  const income = (await lib.send("api/categories-get", {}))
    .filter((c) => c.is_income)
    .map((c) => ({ id: c.id, name: c.name }));
  return { schedules, income };
}

// validateAutomation.ts, with the short messages from automationMessages.tsx.
function problem(template: Template, all: Template[], { schedules, income }: Context): string | null {
  const adjustmentOutOfRange =
    (template.type === "schedule" || template.type === "average") &&
    template.adjustmentType === "percent" &&
    template.adjustment !== undefined &&
    (template.adjustment <= -100 || template.adjustment > 1000);
  switch (template.type) {
    case "schedule": {
      if (!template.scheduleId && !template.name) return "Pick a schedule";
      const match = schedules.find((s) =>
        template.scheduleId ? s.id === template.scheduleId : s.name === template.name,
      );
      if (!match) return `No schedule named “${template.name ?? ""}”`;
      return adjustmentOutOfRange ? "Adjustment out of range" : null;
    }
    case "average":
      return adjustmentOutOfRange ? "Adjustment out of range" : null;
    case "refill":
      return all.some((t) => t.type === "limit") ? null : "Add a balance cap";
    case "limit":
      return all.some((t) => t.type !== "limit" && t.type !== "goal" && t.type !== "error")
        ? null
        : "Add an automation that contributes funds";
    case "percentage": {
      if (!template.category) return "Pick a source category";
      if (template.percent <= 0 || template.percent > 100)
        return `${template.percent}% must be between 0 and 100`;
      const sources = new Set([...specialSources, ...income.flatMap((c) => [c.id, c.name.toLowerCase()])]);
      if (!sources.has(template.category) && !sources.has(template.category.toLowerCase()))
        return "Pick a valid income category";
      return null;
    }
    case "by":
    case "spend": {
      if (!template.month || !months.isValidYearMonth(template.month)) return "Pick a target month";
      if (
        months.differenceInCalendarMonths(template.month, months.currentMonth()) < 0 &&
        !template.annual &&
        !template.repeat
      )
        return `${months.format(template.month, "MMM yyyy")} has already passed`;
      if (template.type === "spend") {
        if (!template.from || !months.isValidYearMonth(template.from)) return "Pick an early-spending start month";
        if (months.differenceInCalendarMonths(template.month, template.from) < 0)
          return "Early spending must start before the target";
      }
      return null;
    }
    default:
      return null;
  }
}

// validatePercentageAllocation and validateSchedulePriorities, plus the web
// editor's limit of one of each singleton type.
function conflicts(templates: Template[]): string[] {
  const result: string[] = [];
  const bySource = new Map<string, number>();
  for (const t of templates)
    if (t.type === "percentage" && t.category) {
      const key = `${t.previous}|${t.category.toLocaleLowerCase()}`;
      bySource.set(key, (bySource.get(key) ?? 0) + t.percent);
    }
  const total = Math.max(0, ...bySource.values());
  if (total > 100) result.push(`Percent automations total ${Math.round(total)}% of income`);
  const priorities = new Set(templates.flatMap((t) => (t.type === "schedule" || t.type === "by" ? [t.priority] : [])));
  if (priorities.size > 1) result.push("All cover schedule and save by date automations must use the same priority");
  const singletons = [["limit", "balance cap"], ["refill", "refill to cap"], ["remainder", "whatever is left"], ["goal", "long-term goal"]];
  for (const [type, label] of singletons)
    if (templates.filter((t) => t.type === type).length > 1) result.push(`Only one ${label} is allowed per category`);
  return result;
}

async function expenseCategory(categoryId: string) {
  const { data } = await lib.send("query", lib.q("categories").filter({ id: categoryId }).select("*").serialize());
  const category = data[0];
  if (!category) throw new Error("This category no longer exists.");
  // Actual allows income category targets only in tracking budgets; this app
  // shows expense categories only.
  if (category.is_income) throw new Error("Set targets for income categories in Actual.");
  return category;
}

function checkMonth(month: string) {
  if (!months.isValidYearMonth(month)) throw new Error("Invalid budget month");
}

async function preview(month: string, categoryId: string, templates: Template[], ctx: Context) {
  const { budgeted, perTemplate } = await lib.send("budget/dry-run-category-template", {
    month,
    categoryId,
    templates,
  });
  return {
    budgeted,
    perTemplate,
    problems: templates.map((t) => problem(t, templates, ctx)),
    conflicts: conflicts(templates),
  };
}

// A category's targets as the web editor shows them.
export async function categoryTargets(categoryId: string, month: string) {
  checkMonth(month);
  const category = await expenseCategory(categoryId);
  const ctx = await context();
  const places = await decimalPlaces();
  const source = category.template_settings?.source === "ui" ? "ui" : "notes";
  const notes = source === "notes" ? await noteTemplates(categoryId) : { note: "", templates: [] };
  const stored: Template[] =
    source === "ui" ? (category.goal_def ? JSON.parse(category.goal_def) : []) : notes.templates;
  const unsupported = stored.flatMap((t) => (t.type === "error" ? [t.line.trim()] : []));
  const templates = unsupported.length
    ? []
    : migrate(stored, ctx.schedules).map((t) => {
        // Notes name a percentage's income category; the editor uses its id.
        if (t.type !== "percentage" || specialSources.includes(t.category)) return t;
        const match = ctx.income.find((c) => c.name.toLowerCase() === t.category.toLowerCase());
        return match ? { ...t, category: match.id } : t;
      });
  return {
    source,
    // Notes lines the editor will replace, as the web editor lists them.
    noteLines: notes.note.split("\n").filter((line) => /^\s*#(template|goal|cleanup)\b/.test(line)).map((l) => l.trim()),
    unsupported,
    templates: templates.map((t) => toNative(t, places)),
    schedules: ctx.schedules,
    incomeCategories: ctx.income,
    preview: unsupported.length ? null : await preview(month, categoryId, templates, ctx),
  };
}

function templates(value: unknown, places: number): Template[] {
  if (!Array.isArray(value)) throw new Error("Invalid targets");
  return value.map((t) => fromNative(t, places));
}

// What the targets would budget this month, and anything to fix before saving.
export async function previewTargets(categoryId: string, month: string, value: unknown) {
  checkMonth(month);
  await expenseCategory(categoryId);
  return preview(month, categoryId, templates(value, await decimalPlaces()), await context());
}

export async function saveTargets(categoryId: string, value: unknown) {
  const category = await expenseCategory(categoryId);
  const list = templates(value, await decimalPlaces());
  const ctx = await context();
  const issue = list.map((t) => problem(t, list, ctx)).find(Boolean) ?? conflicts(list)[0];
  if (issue) throw new Error(issue);
  // Like the web editor, keep the category's #cleanup lines: Actual ignores
  // its notes once the editor manages its targets.
  if (category.template_settings?.source !== "ui") await lib.send("budget/store-note-cleanups", [categoryId]);
  await lib.send("budget/set-category-automations", {
    categoriesWithTemplates: [{ id: categoryId, templates: list }],
    source: "ui",
  });
}

// Applies targets as Actual's budget menus do: to one category, to categories
// with nothing budgeted yet, or overwriting every category with targets.
export async function applyTargets(month: string, categoryId: string | null, overwrite: boolean) {
  checkMonth(month);
  let result: TemplateNotification;
  if (categoryId) {
    await expenseCategory(categoryId);
    result = await lib.send("budget/apply-single-template", { month, category: categoryId });
  } else result = await lib.send(overwrite ? "budget/overwrite-goal-template" : "budget/apply-goal-template", { month });
  if (result.message === "template-errors")
    throw new Error("There were errors interpreting some targets:\n\n" + (result.pre ?? ""));
  if (result.message === "templates-applied") {
    const count = result.count ?? 0;
    return { message: `Applied targets to ${count} ${count === 1 ? "category" : "categories"}.` };
  }
  return { message: "Everything is up to date." };
}
