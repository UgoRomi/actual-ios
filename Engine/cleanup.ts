// End of month cleanup: categories send their leftover to To Budget or a named
// pool, and others receive a share of it. The settings follow desktop-client's
// CleanupAutomation editor and cleanupModel; Actual's handlers store and run them.
import { lib } from "@actual/core";
import { getBudgetType } from "@actual/source/server/budget/base.ts";
import { parse } from "@actual/source/server/budget/cleanup-template.pegjs";
import type { TemplateNotification } from "@actual/source/server/budget/template-notification.ts";
import { sheetForMonth } from "@actual/source/shared/months.ts";
import type { CleanupTemplate } from "@actual/source/types/models/cleanup-templates.ts";
import type { Template } from "@actual/source/types/models/templates.ts";
import { month as checkMonth, type Obj } from "./args";
import { context, editorForm, expenseCategory, noteTemplates } from "./targets";

// Pools cross the bridge by name, which Actual keeps unique whatever the case.
type Row = { role: "source" | "sink" | "overspend"; pool: string | null; weight: number };

function envelopeOnly() {
  if (getBudgetType() === "tracking") throw new Error("End of month cleanup is for envelope budgets.");
}

function pools(): { id: string; name: string; tombstone: number }[] {
  return lib.db.runQuery("SELECT id, name, tombstone FROM cleanup_groups", [], true) as {
    id: string;
    name: string;
    tombstone: number;
  }[];
}

// cleanup-template-notes.ts parseCleanupNote. Reading stores nothing: opening
// a category here must not change it.
function noteRows(note: string): Row[] {
  const rows: Row[] = [];
  for (const line of note.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed.toLowerCase().startsWith("#cleanup ")) continue;
    try {
      const raw = parse(trimmed);
      const pool = raw.group?.trim() || null;
      if (raw.type === "source") rows.push({ role: "source", pool, weight: 1 });
      else if (raw.type === "sink") rows.push({ role: "sink", pool, weight: raw.weight ?? 1 });
      else if (pool) rows.push({ role: "overspend", pool, weight: 1 });
    } catch {
      // Like Actual, skip lines it cannot read.
    }
  }
  return rows;
}

// A category's cleanup settings, as the web editor reads them, and the pools to choose from.
export async function categoryCleanup(categoryId: string) {
  envelopeOnly();
  const category = await expenseCategory(categoryId);
  const all = pools();
  const source = category.template_settings?.source === "ui" ? "ui" : "notes";
  let rows: Row[];
  let noteLines: string[] = [];
  if (source === "ui") {
    const stored: CleanupTemplate[] = category.cleanup_def ? JSON.parse(category.cleanup_def) : [];
    const name = (id: string | null) => (id === null ? null : (all.find((p) => p.id === id)?.name ?? "Unknown pool"));
    rows = stored.map((row) => ({
      role: row.role,
      pool: name(row.groupId),
      weight: row.role === "sink" ? row.weight : 1,
    }));
  } else {
    const [stored] = lib.db.runQuery("SELECT note FROM notes WHERE id = ?", [categoryId], true) as { note: string | null }[];
    const note = stored?.note ?? "";
    rows = noteRows(note);
    noteLines = note.split("\n").filter((line) => /^\s*#(template|goal|cleanup)\b/.test(line)).map((l) => l.trim());
  }
  return {
    source,
    rows,
    // Notes lines Actual ignores once the settings are saved here.
    noteLines,
    pools: all.filter((p) => !p.tombstone).map((p) => p.name).sort((a, b) => a.localeCompare(b)),
  };
}

function rows(value: unknown): Row[] {
  if (!Array.isArray(value)) throw new Error("Invalid cleanup settings");
  return value.map((item) => {
    const raw = (item ?? {}) as Obj;
    const role = raw.role;
    if (role !== "source" && role !== "sink" && role !== "overspend") throw new Error("Invalid cleanup settings");
    const pool = typeof raw.pool === "string" && raw.pool.trim() ? raw.pool.trim() : null;
    if (role === "overspend" && !pool) throw new Error("Choose a pool.");
    const weight = role === "sink" ? raw.weight : 1;
    if (typeof weight !== "number" || !Number.isSafeInteger(weight) || weight < 1)
      throw new Error("Enter a weight of 1 or more.");
    return { role, pool, weight };
  });
}

// Saves as the web editor does: with the category's targets, which the editor
// then manages. Targets still in notes move to the editor unchanged.
export async function saveCleanup(categoryId: string, value: unknown) {
  envelopeOnly();
  const category = await expenseCategory(categoryId);
  const list = rows(value);
  let templates: Template[];
  if (category.template_settings?.source === "ui") templates = category.goal_def ? JSON.parse(category.goal_def) : [];
  else {
    const notes = await noteTemplates(categoryId);
    if (notes.templates.some((t) => t.type === "error"))
      throw new Error("Actual can’t read some of this category’s targets. Fix them in Targets first.");
    templates = editorForm(notes.templates, await context());
  }
  const ids = new Map<string, string>();
  for (const row of list)
    if (row.pool && !ids.has(row.pool.toLowerCase()))
      ids.set(row.pool.toLowerCase(), (await lib.send("budget/create-cleanup-group", { name: row.pool })).id);
  const id = (row: Row) => (row.pool ? (ids.get(row.pool.toLowerCase()) ?? null) : null);
  const cleanup: CleanupTemplate[] = list.flatMap((row): CleanupTemplate[] => {
    const groupId = id(row);
    if (row.role === "source") return [{ role: "source", groupId }];
    if (row.role === "sink") return [{ role: "sink", groupId, weight: row.weight }];
    return groupId ? [{ role: "overspend", groupId }] : [];
  });
  await lib.send("budget/set-category-automations", {
    categoriesWithTemplates: [{ id: categoryId, templates, cleanup }],
    source: "ui",
  });
}

async function toBudget(month: string): Promise<number> {
  const { value } = await lib.send("get-cell", { sheetName: sheetForMonth(month), name: "to-budget" });
  return typeof value === "number" ? value : 0;
}

// Runs Actual's End of month cleanup, with the messages its budget page shows.
export async function cleanupMonth(month: string) {
  checkMonth(month);
  envelopeOnly();
  const before = await toBudget(month);
  const result: TemplateNotification = await lib.send("budget/cleanup-goal-template", { month });
  // Actual reports only categories that sent leftover; the app also says what left To Budget.
  const assigned = before - (await toBudget(month));
  const plural = (count: number, one: string, many: string) => `${count} ${count === 1 ? one : many}`;
  const funded =
    `Successfully returned funds from ${plural(result.sourceCount ?? 0, "source", "sources")} and funded ` +
    `${plural(result.sinkCount ?? 0, "sinking fund", "sinking funds")}.`;
  const details = result.pre ? "\n\n" + result.pre : "";
  switch (result.message) {
    case "cleanup-applied":
      return { message: funded, upToDate: false, assigned };
    case "cleanup-applied-with-errors":
      return { message: funded + " There were errors interpreting some templates:" + details, upToDate: false, assigned };
    case "cleanup-no-funds":
      return { message: "Funds not available:" + details, upToDate: false, assigned };
    case "template-errors":
      throw new Error("There were errors interpreting some templates:" + details);
    default:
      return { message: "All categories were up to date.", upToDate: true, assigned };
  }
}
