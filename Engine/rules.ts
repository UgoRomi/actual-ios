// Transaction rules, as Actual's rules pages list, edit, and apply them.
import { lib } from "@actual/core";
import { getFieldError } from "@actual/source/shared/rules.ts";

type Obj = Record<string, unknown>;

function text(value: unknown): string {
  return typeof value === "string" ? value : "";
}

async function all() {
  return (await lib.send("rules-get")) as unknown as Obj[];
}

export async function rulesList() {
  return (await all()).map((rule) => ({
    id: rule.id,
    stage: rule.stage ?? null,
    conditionsOp: rule.conditionsOp === "or" ? "or" : "and",
    conditions: rule.conditions ?? [],
    actions: rule.actions ?? [],
  }));
}

// Actual's validation errors, one per condition or action, as its editor shows them.
function message(error: Obj): string {
  const lines: string[] = [];
  const conditions = (error.conditionErrors ?? []) as unknown[];
  const actions = (error.actionErrors ?? []) as unknown[];
  conditions.forEach((e, i) => e && lines.push(`Condition ${i + 1}: ${getFieldError(e)}`));
  actions.forEach((e, i) => e && lines.push(`Action ${i + 1}: ${getFieldError(e)}`));
  return lines.join("\n") || "This rule is not valid.";
}

function rule(args: Obj) {
  const conditions = Array.isArray(args.conditions) ? args.conditions : [];
  const actions = Array.isArray(args.actions) ? args.actions : [];
  if (!actions.length) throw new Error("Add at least one action.");
  const stage = args.stage === "pre" || args.stage === "post" ? args.stage : null;
  return { stage, conditionsOp: args.conditionsOp === "or" ? "or" : "and", conditions, actions };
}

// Filters matching the rule's conditions, as the editor's matching transactions list uses.
async function matching(args: Obj) {
  const conditions = Array.isArray(args.conditions) ? args.conditions : [];
  const { filters } = await lib.send("make-filters-from-conditions", { conditions } as never);
  if (!filters.length) return [];
  const key = args.conditionsOp === "or" ? "$or" : "$and";
  const { data } = await lib.send(
    "query",
    lib.q("transactions").filter({ [key]: filters }).select("*").serialize(),
  );
  return data as Obj[];
}

export async function ruleCommand(method: string, args: Obj): Promise<unknown> {
  switch (method) {
    case "saveRule": {
      const id = text(args.id);
      const value = rule(args);
      if (id && !(await all()).some((r) => r.id === id)) throw new Error("This rule no longer exists.");
      const result = (await lib.send(id ? "rule-update" : "rule-add", (id ? { id, ...value } : value) as never)) as Obj;
      if (result && result.error) throw new Error(message(result.error as Obj));
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
    case "ruleMatches":
      return { count: (await matching(args)).length };
    case "applyRule": {
      // As Actual's editor's "Apply actions": run the actions on every matching transaction.
      const value = rule(args);
      const transactions = await matching(args);
      if (!transactions.length) return { count: 0 };
      const result = (await lib.send("rule-apply-actions", {
        transactions,
        actions: value.actions,
      } as never)) as Obj | null;
      const errors = (result?.errors ?? []) as string[];
      if (errors.length) throw new Error(errors.join("\n"));
      return { count: transactions.length };
    }
    default:
      throw new Error("Unknown operation: " + method);
  }
}

export const ruleWrites = ["saveRule", "deleteRule", "applyRule"];
