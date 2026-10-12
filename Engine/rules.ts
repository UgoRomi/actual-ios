// Transaction rules, as Actual's rules pages list, edit, and apply them.
import { lib } from "@actual/core";
import { getFieldError } from "@actual/source/shared/rules.ts";
import { text, type Obj } from "./args";

async function all() {
  return (await lib.send("rules-get")) as unknown as Obj[];
}

function serialize(rule: Obj) {
  return {
    id: rule.id,
    stage: rule.stage ?? null,
    conditionsOp: rule.conditionsOp === "or" ? "or" : "and",
    conditions: rule.conditions ?? [],
    actions: rule.actions ?? [],
  };
}

// As Actual's rules pages: every rule, or a payee's, in the order they run,
// leaving out the rules of completed schedules.
export async function rulesList(args: Obj = {}) {
  const payee = text(args.payeeId);
  const rules = (payee ? await lib.send("payees-get-rules", { id: payee }) : await all()) as unknown as Obj[];
  const { data } = await lib.send("query", lib.q("schedules").select(["rule", "completed"]).serialize());
  const completed = new Set((data as Obj[]).filter((s) => s.completed).map((s) => s.rule));
  return rules.filter((rule) => !completed.has(rule.id)).map(serialize);
}

// Actual's validation errors, one per condition or action, as its editor shows them.
function message(error: Obj, actions: Obj[]): string {
  const lines: string[] = [];
  const conditionErrors = (error.conditionErrors ?? []) as unknown[];
  const actionErrors = (error.actionErrors ?? []) as unknown[];
  conditionErrors.forEach((e, i) => e && lines.push(`Condition ${i + 1}: ${getFieldError(e)}`));
  actionErrors.forEach((e, i) => {
    if (!e) return;
    // Split actions are numbered within their split, as the editor lists them.
    const split = Number((actions[i]?.options as Obj | undefined)?.splitIndex ?? 0);
    const place = actions.slice(0, i + 1).filter((a) => Number((a.options as Obj | undefined)?.splitIndex ?? 0) === split).length;
    lines.push(`${split ? `Split ${split}, action` : "Action"} ${place}: ${getFieldError(e)}`);
  });
  return lines.join("\n") || "This rule is not valid.";
}

function splitIndex(action: Obj) {
  return Number((action.options as Obj | undefined)?.splitIndex ?? 0);
}

function rule(args: Obj) {
  const conditions = Array.isArray(args.conditions) ? args.conditions : [];
  const actions = Array.isArray(args.actions) ? (args.actions as Obj[]) : [];
  if (!actions.length) throw new Error("Add at least one action.");
  const stage = args.stage === "pre" || args.stage === "post" ? args.stage : null;
  // As Actual's editor saves them: the actions before any split, then each split's in turn.
  const sorted = actions.map((a, i) => [a, i] as const).sort(([a, i], [b, j]) => splitIndex(a) - splitIndex(b) || i - j);
  return { stage, conditionsOp: args.conditionsOp === "or" ? "or" : "and", conditions, actions: sorted.map(([a]) => a) };
}

// Transactions matching the rule's conditions, as the editor's matching transactions list shows them.
// A rule that splits matches whole transactions, not split parts.
async function matching(args: Obj) {
  const conditions = Array.isArray(args.conditions) ? args.conditions : [];
  const actions = Array.isArray(args.actions) ? (args.actions as Obj[]) : [];
  const { filters } = await lib.send("make-filters-from-conditions", { conditions } as never);
  if (!filters.length) return [];
  const key = args.conditionsOp === "or" ? "$or" : "$and";
  const parentsOnly = actions.some((a) => splitIndex(a) > 0) ? { is_child: false } : {};
  const { data } = await lib.send(
    "query",
    lib.q("transactions").filter({ [key]: filters, ...parentsOnly }).select("*").serialize(),
  );
  return (data as Obj[]).sort((a, b) => String(b.date).localeCompare(String(a.date)));
}

// A rule for transactions like this one, as Actual's register's "Create rule" drafts it:
// its payee and approximate amount, then its category or its split's parts.
async function draftFromTransaction(id: string) {
  const query = (filter: Obj) =>
    lib.send("query", lib.q("transactions").filter(filter).select("*").options({ splits: "all" }).serialize());
  const [transaction] = (await query({ id })).data as Obj[];
  if (!transaction) throw new Error("This transaction no longer exists.");
  const children = transaction.is_parent ? ((await query({ parent_id: id })).data as Obj[]) : [];
  const payee = transaction.imported_payee
    ? { field: "imported_payee", op: "is", value: transaction.imported_payee, type: "string" }
    : { field: "payee", op: "is", value: transaction.payee ?? null, type: "id" };
  return {
    id: "",
    stage: null,
    conditionsOp: "and",
    conditions: [payee, { field: "amount", op: "isapprox", value: transaction.amount, type: "number" }],
    actions: children.length
      ? children.flatMap((child, index) => [
          { op: "set-split-amount", value: child.amount, options: { splitIndex: index + 1, method: "fixed-amount" } },
          { op: "set", field: "category", value: child.category ?? null, type: "id", options: { splitIndex: index + 1 } },
        ])
      : [{ op: "set", field: "category", value: transaction.category ?? null, type: "id", options: { splitIndex: 0 } }],
  };
}

export async function ruleCommand(method: string, args: Obj): Promise<unknown> {
  switch (method) {
    case "saveRule": {
      const id = text(args.id);
      const value = rule(args);
      if (id && !(await all()).some((r) => r.id === id)) throw new Error("This rule no longer exists.");
      const result = (await lib.send(id ? "rule-update" : "rule-add", (id ? { id, ...value } : value) as never)) as Obj;
      if (result && result.error) throw new Error(message(result.error as Obj, value.actions));
      return { id: id || result.id };
    }
    case "deleteRule": {
      const id = text(args.id);
      if (!(await all()).some((r) => r.id === id)) throw new Error("This rule no longer exists.");
      // Actual keeps a schedule's rule while the schedule exists.
      if ((await lib.send("rule-delete", id as never)) === false)
        throw new Error("This rule belongs to a schedule. Delete the schedule instead.");
      return {};
    }
    case "deleteRules": {
      // As Actual's rules page deletes selected rules, keeping schedules' rules.
      const ids = (Array.isArray(args.ids) ? args.ids : []).map((id) => text(id)).filter(Boolean);
      const { someDeletionsFailed } = (await lib.send("rule-delete-all", ids as never)) as Obj;
      if (someDeletionsFailed) throw new Error("Some rules were not deleted because they belong to schedules.");
      return {};
    }
    case "ruleMatches": {
      const transactions = await matching(args);
      return {
        count: transactions.length,
        transactions: transactions.map((t) => ({
          id: t.id,
          date: t.date,
          amount: t.amount,
          payeeId: t.payee ?? null,
          accountId: t.account,
          categoryId: t.category ?? null,
          notes: t.notes ?? "",
        })),
      };
    }
    case "applyRule": {
      // As Actual's editor's "Apply actions": run the editor's actions on the chosen matching
      // transactions, or on every one.
      const value = rule(args);
      let transactions = await matching(args);
      if (Array.isArray(args.ids)) {
        const ids = new Set(args.ids.map((id) => text(id)));
        transactions = transactions.filter((t) => ids.has(text(t.id)));
      }
      if (!transactions.length) return { count: 0 };
      const result = (await lib.send("rule-apply-actions", {
        transactions,
        actions: value.actions,
      } as never)) as Obj | null;
      const errors = (result?.errors ?? []) as string[];
      if (errors.length) throw new Error(errors.join("\n"));
      return { count: transactions.length };
    }
    case "ruleFromTransaction":
      return draftFromTransaction(text(args.id));
    default:
      throw new Error("Unknown operation: " + method);
  }
}

export const ruleWrites = ["saveRule", "deleteRule", "deleteRules", "applyRule"];
export const ruleReads = ["ruleMatches", "ruleFromTransaction"];
