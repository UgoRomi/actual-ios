// Schedules, as Actual's mobile schedules pages list and edit them, with the
// actions of its schedules table: post, skip, complete, restart, and delete.
import { lib } from "@actual/core";
import { createPayee } from "@actual/source/server/accounts/payees.ts";
import { runMutator } from "@actual/source/server/mutators.ts";
import * as months from "@actual/source/shared/months.ts";
import {
  computeSchedulePreviewTransactions,
  extractScheduleConds,
  getHasTransactionsQuery,
  getStatus,
  scheduleIsRecurring,
} from "@actual/source/shared/schedules.ts";
import { day, integer, text, type Obj } from "./args";

const invalidAmount = "A valid amount is required";

async function all(): Promise<Obj[]> {
  return (await lib.send("query", lib.q("schedules").select("*").serialize())).data as Obj[];
}
async function find(id: unknown): Promise<Obj> {
  const schedule = (await all()).find((s) => s.id === id);
  if (!schedule) throw new Error("This schedule no longer exists.");
  return schedule;
}

async function statuses(list: Obj[]) {
  const { data } = await lib.send("query", getHasTransactionsQuery(list as never).serialize());
  const paid = new Set((data as Obj[]).filter(Boolean).map((row) => row.schedule));
  const upcoming = String((await lib.send("preferences/get")).upcomingScheduledTransactionLength || "7");
  const status = new Map(
    list.map((s) => [
      text(s.id),
      getStatus(text(s.next_date), Boolean(s.completed), paid.has(s.id), text(s.custom_upcoming_length) || upcoming),
    ]),
  );
  return { status, upcoming };
}

// Upcoming scheduled transactions, as Actual's registers list them before the
// saved ones: each date within the upcoming period, with rules applied, as
// desktop-client's usePreviewTransactions does.
export async function schedulePreviews() {
  const list = await all();
  const { status, upcoming } = await statuses(list);
  const previews = computeSchedulePreviewTransactions(list as never, status as never, upcoming);
  const payees = new Map((await lib.send("api/payees-get")).map((p) => [p.id, p]));
  const categories = new Map(
    [...(await lib.send("api/categories-get", {})), ...(await lib.send("api/categories-get", { hidden: true }))].map(
      (c) => [c.id, c.name],
    ),
  );
  const byId = new Map(list.map((s) => [text(s.id), s]));
  const result = [];
  for (const preview of previews as Obj[]) {
    const ruled = (await lib.send("rules-run", { transaction: preview } as never)) as Obj;
    const schedule = byId.get(text(preview.schedule));
    const payee = payees.get(text(ruled.payee));
    result.push({
      id: text(preview.id),
      scheduleId: text(preview.schedule),
      scheduleName: text(schedule?.name) || null,
      accountId: text(ruled.account) || null,
      date: text(ruled.date),
      amount: typeof ruled.amount === "number" ? ruled.amount : 0,
      payeeName: payee?.name ?? null,
      categoryName: ruled.category ? categories.get(text(ruled.category)) ?? null : null,
      isTransfer: Boolean(payee?.transfer_acct),
      status: status.get(text(preview.schedule)),
      // A later date than the next one is always upcoming.
      forceUpcoming: Boolean(preview.forceUpcoming),
      recurring: scheduleIsRecurring(extractScheduleConds(schedule?._conditions as never).date as never),
    });
  }
  return result;
}

// Every schedule with its status, as useSchedules computes it.
export async function schedules() {
  const list = await all();
  const { status } = await statuses(list);
  return list.map((s) => ({
    id: s.id,
    name: s.name || null,
    payeeId: s._payee ?? null,
    accountId: s._account ?? null,
    amount: s._amount ?? 0,
    amountOp: s._amountOp ?? "isapprox",
    date: s._date ?? null,
    nextDate: s.next_date ?? null,
    completed: Boolean(s.completed),
    postsTransaction: Boolean(s.posts_transaction),
    status: status.get(text(s.id)),
  }));
}

function patterns(value: unknown) {
  if (value == null) return [];
  if (!Array.isArray(value)) throw new Error("Choose valid specific days.");
  return value.map((item) => {
    const pattern = (item ?? {}) as Obj;
    const type = text(pattern.type);
    const day = pattern.value;
    if (!["day", "SU", "MO", "TU", "WE", "TH", "FR", "SA"].includes(type)) throw new Error("Choose valid specific days.");
    if (typeof day !== "number" || !Number.isInteger(day) || !(day === -1 || (day >= 1 && day <= 31)))
      throw new Error("Choose valid specific days.");
    return { type, value: day };
  });
}

// A repeating date, checked the way Actual's date editor limits it.
function recurrence(value: Obj) {
  const frequency = text(value.frequency);
  if (!["daily", "weekly", "monthly", "yearly"].includes(frequency)) throw new Error("Choose how often it repeats.");
  const interval = value.interval ?? 1;
  if (typeof interval !== "number" || !Number.isSafeInteger(interval) || interval < 1)
    throw new Error("Repeat at least every 1 period.");
  const endMode = text(value.endMode) || "never";
  if (!["never", "after_n_occurrences", "on_date"].includes(endMode)) throw new Error("Choose when it ends.");
  const endOccurrences = value.endOccurrences ?? 1;
  if (typeof endOccurrences !== "number" || !Number.isSafeInteger(endOccurrences) || endOccurrences < 1)
    throw new Error("End after at least 1 occurrence.");
  const weekendSolveMode = text(value.weekendSolveMode) || "after";
  if (!["before", "after"].includes(weekendSolveMode)) throw new Error("Choose how weekends move the date.");
  const start = day(value.start, "start date");
  return {
    start,
    frequency,
    interval,
    // Specific days of a monthly schedule, as Actual's date editor sets them:
    // a day of the month, or the nth weekday, where -1 is the last.
    patterns: frequency === "monthly" ? patterns(value.patterns) : [],
    skipWeekend: value.skipWeekend === true,
    weekendSolveMode,
    endMode,
    endOccurrences,
    endDate: endMode === "on_date" ? day(value.endDate, "end date") : text(value.endDate) || start,
  };
}

async function save(args: Obj) {
  const id = text(args.id);
  const existing = id ? await find(id) : null;
  const name = text(args.name).trim();
  if (name && (await all()).some((s) => s.id !== id && s.name === name))
    throw new Error("There is already a schedule with this name");

  let payee: string | null = text(args.payeeId) || null;
  const payeeName = text(args.payeeName).trim();
  if (!payee && payeeName) payee = await runMutator(() => createPayee(payeeName));
  const accountId = text(args.accountId) || null;
  if (accountId && !(await lib.send("accounts-get")).some((a) => a.id === accountId))
    throw new Error("This account no longer exists. Choose another account.");

  const op = text(args.amountOp) || "isapprox";
  if (!["is", "isapprox", "isbetween"].includes(op)) throw new Error("Choose how the amount matches.");
  let amount: number | { num1: number; num2: number };
  if (op === "isbetween") {
    const range = (args.amount ?? {}) as Obj;
    amount = { num1: integer(range.num1, invalidAmount), num2: integer(range.num2, invalidAmount) };
  } else amount = integer(args.amount, invalidAmount);

  const rawDate = args.date;
  if (rawDate == null) throw new Error("Date is required");
  const date = typeof rawDate === "string" ? day(rawDate, "date") : recurrence(rawDate as Obj);

  // As desktop-client's updateScheduleConditions: keep each condition's other
  // settings, and always replace the amount.
  const conds = extractScheduleConds((existing?._conditions ?? []) as never) as Record<string, Obj | undefined>;
  const update = (cond: Obj | undefined, condOp: string, field: string, value: unknown) =>
    cond ? { ...cond, value } : value != null || field === "payee" ? { op: condOp, field, value } : null;
  const conditions = [
    update(conds.payee, "is", "payee", payee),
    update(conds.account, "is", "account", accountId),
    update(conds.date, "isapprox", "date", date),
    { op, field: "amount", value: amount },
  ].filter((c) => c != null);

  const schedule = { name, posts_transaction: args.postsTransaction === true };
  if (existing) await lib.send("schedule/update", { schedule: { id, ...schedule }, conditions } as never);
  else await lib.send("schedule/create", { schedule, conditions } as never);
}

export async function scheduleCommand(method: string, args: Obj): Promise<unknown> {
  switch (method) {
    case "saveSchedule":
      await save(args);
      return {};
    case "deleteSchedule":
      await lib.send("schedule/delete", { id: (await find(args.id)).id } as never);
      return {};
    case "skipSchedule":
      await lib.send("schedule/skip-next-date", { id: (await find(args.id)).id } as never);
      return {};
    case "postSchedule": {
      // Posts on the next date, or today, as Actual's schedules menu offers.
      const schedule = await find(args.id);
      if (!schedule._account) throw new Error("Choose an account for this schedule before posting it.");
      await lib.send("schedule/post-transaction", { id: schedule.id, today: args.today === true } as never);
      return {};
    }
    case "completeSchedule": {
      const schedule = await find(args.id);
      if (args.completed === true) await lib.send("schedule/update", { schedule: { id: schedule.id, completed: true } } as never);
      // Restarting finds the next date again.
      else
        await lib.send("schedule/update", {
          schedule: { id: schedule.id, completed: false },
          resetNextDate: true,
        } as never);
      return {};
    }
    case "scheduleTransactions": {
      // A schedule's linked transactions, and ones its conditions match that are not linked yet,
      // as the transactions list in Actual's schedule editor shows them.
      const schedule = await find(args.id);
      const summary = (rows: Obj[]) =>
        rows.map((row) => ({
          id: row.id,
          date: row.date,
          amount: row.amount,
          accountId: row.account ?? null,
          payeeId: row.payee ?? null,
          notes: row.notes ?? "",
        }));
      const { data: linked } = await lib.send(
        "query",
        lib.q("transactions").filter({ schedule: schedule.id }).select("*").orderBy({ date: "desc" }).serialize(),
      );
      const { filters } = await lib.send("make-filters-from-conditions", {
        conditions: ((schedule._conditions ?? []) as Obj[]).filter((c) => c.field !== "date"),
      } as never);
      const { data: matching } = filters.length
        ? await lib.send(
            "query",
            lib.q("transactions").filter({ $and: [...filters, { schedule: null }] }).select("*")
              .orderBy({ date: "desc" }).limit(50).serialize(),
          )
        : { data: [] };
      return { linked: summary(linked as Obj[]), matching: summary(matching as Obj[]) };
    }
    case "linkScheduleTransactions": {
      const schedule = await find(args.id);
      const ids = Array.isArray(args.transactionIds) ? args.transactionIds.map((id) => text(id)).filter(Boolean) : [];
      if (!ids.length) throw new Error("Choose transactions to link.");
      const link = args.link !== false;
      await lib.send("transactions-batch-update", {
        updated: ids.map((id) => ({ id, schedule: link ? schedule.id : null })),
      } as never);
      return {};
    }
    case "upcomingDates": {
      const count = typeof args.count === "number" ? Math.min(Math.max(Math.round(args.count), 1), 12) : 5;
      const config = args.date;
      if (typeof config === "string") return [day(config, "date")];
      return lib.send("schedule/get-upcoming-dates", { config: recurrence((config ?? {}) as Obj), count } as never);
    }
    default:
      throw new Error("Unknown operation: " + method);
  }
}

export const scheduleWrites = [
  "saveSchedule", "deleteSchedule", "skipSchedule", "postSchedule", "completeSchedule", "linkScheduleTransactions",
];
