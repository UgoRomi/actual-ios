// Importing transaction files, as Actual's import dialog does: OFX/QFX, QIF,
// CSV/TSV, and CAMT XML are parsed by loot-core, CSV columns are mapped, a
// preview marks duplicates of existing transactions, and the import matches
// them as bank sync does. Date and amount parsing are ported from
// desktop-client's ImportTransactionsModal/utils.ts.
import { Buffer } from "buffer";

import { lib } from "@actual/core";
import { getPrefs, savePrefs } from "@actual/prefs";
import { amountToInteger, looselyParseAmount } from "@actual/source/shared/util.ts";

import { removeFile, writeFile } from "./adapters/fs";
import { text, type Obj } from "./args";

type Mapping = { date: string | null; payee: string | null; notes: string | null; amount: string | null;
  inflow: string | null; outflow: string | null; category: string | null };

const dateFormats = ["yyyy mm dd", "yy mm dd", "mm dd yyyy", "mm dd yy", "dd mm yyyy", "dd mm yy"];

// desktop-client's parseDate: month names become numbers, then the parts are ordered.
function parseDate(value: unknown, order: string): string | null {
  if (typeof value !== "string") return null;
  const months = ["jan(\\.|uary)?", "feb(\\.|ruary)?", "mar(\\.|ch)?", "apr(\\.|il)?", "may\\.?", "jun(\\.|e)?",
    "jul(\\.|y)?", "aug(\\.|ust)?", "sep(\\.|tember)?", "oct(\\.|ober)?", "nov(\\.|ember)?", "dec(\\.|ember)?"];
  const groups = (a: number, b: number) => (str: string) => {
    let named = str;
    months.forEach((pattern, index) => {
      named = named.replace(new RegExp(`\\b${pattern}\\b`, "i"), String(index + 1).padStart(2, "0"));
    });
    const parts = named.replace(/^[^\d]+/, "").replace(/[^\d]+$/, "").split(/[^\d]+/);
    if (parts.length >= 3) return parts.slice(0, 3);
    const digits = str.replace(/[^\d]/g, "");
    return [digits.slice(0, a), digits.slice(a, a + b), digits.slice(a + b)];
  };
  const pad = (v: string) => (v && v.length === 1 ? "0" + v : v);
  const yearFirst = groups(4, 2), twoDigits = groups(2, 2);
  let parts: string[], year: string, month: string, day: string;
  switch (order) {
    case "dd mm yyyy": parts = twoDigits(value); [day, month, year] = parts; break;
    case "dd mm yy": parts = twoDigits(value); [day, month] = parts; year = `20${parts[2]}`; break;
    case "yyyy mm dd": parts = yearFirst(value); [year, month, day] = parts; break;
    case "yy mm dd": parts = twoDigits(value); year = `20${parts[0]}`; [, month, day] = parts; break;
    case "mm dd yy": parts = twoDigits(value); [month, day] = parts; year = `20${parts[2]}`; break;
    default: parts = twoDigits(value); [month, day, year] = parts;
  }
  const parsed = `${year}-${pad(month)}-${pad(day)}`;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(parsed)) return null;
  const date = new Date(parsed + "T12:00:00Z");
  return isNaN(date.getTime()) || date.toISOString().slice(0, 10) !== parsed ? null : parsed;
}

// desktop-client's getInitialDateFormat: the first format that reads the first row's date.
function guessDateFormat(rows: Obj[], field: string | null): string {
  if (!rows.length || !field) return "yyyy mm dd";
  return dateFormats.find((format) => parseDate(rows[0][field], format)) ?? "mm dd yyyy";
}

// desktop-client's getInitialMappings: headers first, then values that look right.
function guessMapping(rows: Obj[]): Mapping {
  const first = rows[0] ?? {};
  const columns = Object.keys(first);
  const byHeader = (name: string) => columns.find((c) => c.toLowerCase().includes(name)) ?? null;
  const used = new Set<string>();
  const take = (column: string | null) => {
    if (column) used.add(column);
    return column;
  };
  const date = take(byHeader("date") ?? columns.find((c) => /^\d+[-/]\d+[-/]\d+$/.test(text(first[c]))) ?? null);
  const amount = take(byHeader("amount") ?? columns.find((c) => !used.has(c) && /^-?[.,\d]+$/.test(text(first[c]))) ?? null);
  const category = take(byHeader("category"));
  const payee = take(byHeader("payee") ?? columns.find((c) => !used.has(c)) ?? null);
  const notes = take(byHeader("notes") ?? columns.find((c) => !used.has(c)) ?? null);
  return { date, payee, notes, amount, inflow: null, outflow: null, category };
}

function fileType(name: string): string {
  const extension = name.toLowerCase().split(".").pop() ?? "";
  if (extension === "tsv") return "csv";
  if (["csv", "qif", "ofx", "qfx", "xml"].includes(extension)) return extension;
  throw new Error("Choose an OFX, QFX, QIF, CSV, TSV, or CAMT XML file.");
}

// desktop-client's parseAmountFields, without in/out columns or a multiplier.
function amountOf(row: Obj, mapping: Mapping, split: boolean, flip: boolean): number | null {
  const parse = (value: unknown) =>
    value == null ? null : typeof value === "number" ? value : looselyParseAmount(text(value));
  let inflow = 0, outflow = 0;
  if (split) {
    outflow = -Math.abs(parse(mapping.outflow ? row[mapping.outflow] : null) || 0);
    inflow = outflow ? 0 : Math.abs(parse(mapping.inflow ? row[mapping.inflow] : null) || 0);
  } else {
    const amount = parse(mapping.amount ? row[mapping.amount] : row.amount);
    if (amount == null) return null;
    if (amount >= 0) inflow = amount;
    else outflow = amount;
  }
  if (flip) [inflow, outflow] = [Math.abs(outflow), -Math.abs(inflow)];
  return outflow || inflow;
}

type Settings = { hasHeaderRow: boolean; delimiter: string; dateFormat: string | null; mapping: Mapping | null;
  splitMode: boolean; flipAmount: boolean };

// Saved per account, as Actual's import dialog saves them on this device.
function savedSettings(accountId: string, type: string, name: string): Settings {
  const prefs = (getPrefs() ?? {}) as Obj;
  const mapping = (() => {
    try { return JSON.parse(text(prefs[`csv-mappings-${accountId}`])) as Mapping; } catch { return null; }
  })();
  return {
    hasHeaderRow: prefs[`csv-has-header-${accountId}`] !== "false",
    delimiter: text(prefs[`csv-delimiter-${accountId}`]) || (name.toLowerCase().endsWith(".tsv") ? "\t" : ","),
    dateFormat: text(prefs[`parse-date-${accountId}-${type}`]) || null,
    mapping,
    splitMode: Boolean(mapping?.inflow || mapping?.outflow),
    flipAmount: prefs[`flip-amount-${accountId}-${type}`] === "true",
  };
}

async function parse(name: string, data: string, type: string, settings: Settings) {
  const path = `/documents/.import-${crypto.randomUUID()}.${type}`;
  await writeFile(path, new Uint8Array(Buffer.from(data, "base64")));
  try {
    const options = type === "csv"
      ? { delimiter: settings.delimiter, hasHeaderRow: settings.hasHeaderRow, skipStartLines: 0, skipEndLines: 0 }
      : type === "ofx" || type === "qfx"
        ? { fallbackMissingPayeeToMemo: true, importNotes: true, swapPayeeAndMemo: false }
        : { importNotes: true, swapPayeeAndMemo: false };
    return (await lib.send("transactions-parse-file", { filepath: path, options } as never)) as {
      errors: { message: string }[]; transactions?: unknown[];
    };
  } finally {
    await removeFile(path).catch(() => {});
  }
}

export async function prepareImport(args: Obj) {
  const accountId = text(args.accountId);
  if (!(await lib.send("accounts-get")).some((a) => a.id === accountId && !a.closed))
    throw new Error("Choose an open account to import into.");
  const name = text(args.fileName);
  const type = fileType(name);
  const given = (args.settings ?? {}) as Partial<Settings>;
  const settings = { ...savedSettings(accountId, type, name), ...given } as Settings;
  const result = await parse(name, text(args.data), type, settings);
  if (result.errors?.length && !result.transactions?.length)
    throw new Error("This file could not be read: " + result.errors.map((e) => e.message).join("; "));

  // CSV rows without a header row are arrays; key them by column number.
  const raw = (result.transactions ?? []).map((row) =>
    Array.isArray(row) ? Object.fromEntries(row.map((v, i) => [String(i + 1), v])) : (row as Obj));
  const columns = type === "csv" ? Object.keys(raw[0] ?? {}) : [];
  const mapping = type === "csv" ? (settings.mapping ?? guessMapping(raw)) : null;
  const dateField = type === "csv" ? mapping!.date : "date";
  const needsFormat = type === "csv" || type === "qif";
  const dateFormat = needsFormat ? (settings.dateFormat ?? guessDateFormat(raw, dateField)) : null;
  const categories = [...(await lib.send("api/categories-get", {})), ...(await lib.send("api/categories-get", { hidden: true }))];

  const transactions: Obj[] = [];
  const problems: string[] = [];
  raw.forEach((row, index) => {
    const date = needsFormat ? parseDate(dateField ? row[dateField] : null, dateFormat!) : text(row.date);
    const amount = type === "csv"
      ? amountOf(row, mapping!, settings.splitMode, settings.flipAmount)
      : settings.flipAmount ? -Number(row.amount) : Number(row.amount);
    if (!date) { problems.push(`Row ${index + 1}: the date could not be read.`); return; }
    if (amount == null || !isFinite(amount)) { problems.push(`Row ${index + 1}: the amount could not be read.`); return; }
    const categoryName = type === "csv" ? (mapping!.category ? text(row[mapping!.category]) : "") : text(row.category);
    const payee = type === "csv" ? (mapping!.payee ? text(row[mapping!.payee]) : "") : text(row.payee_name);
    transactions.push({
      trx_id: String(index),
      date,
      amount: amountToInteger(amount),
      payee_name: payee,
      imported_payee: type === "csv" ? payee : text(row.imported_payee) || payee,
      notes: type === "csv" ? (mapping!.notes ? text(row[mapping!.notes]) : "") : text(row.notes),
      ...(row.imported_id ? { imported_id: row.imported_id } : {}),
      category: categories.find((c) => c.name === categoryName)?.id ?? null,
      cleared: true,
    });
  });

  // Actual's preview: which rows match existing transactions, and which it would skip.
  const preview = transactions.length
    ? ((await lib.send("transactions-import", {
        accountId, transactions, isPreview: true,
      } as never)) as { updatedPreview?: { transaction: Obj; existing?: Obj; ignored?: boolean }[] })
    : {};
  const matches = new Map((preview.updatedPreview ?? []).map((entry) => [text(entry.transaction.trx_id), entry]));
  return {
    fileType: type,
    columns,
    settings: { ...settings, mapping, dateFormat },
    problems: [...(result.errors ?? []).map((e) => e.message), ...problems],
    transactions: transactions.map((transaction) => {
      const match = matches.get(text(transaction.trx_id));
      return {
        payload: transaction,
        // A matched transaction is updated in place; an ignored one is already the same or locked.
        existing: Boolean(match?.existing),
        ignored: Boolean(match?.ignored),
      };
    }),
  };
}

export async function commitImport(args: Obj) {
  const accountId = text(args.accountId);
  const type = fileType(text(args.fileName));
  const settings = (args.settings ?? {}) as Partial<Settings>;
  const transactions = (Array.isArray(args.transactions) ? args.transactions : []).map((row) => {
    const { trx_id: _id, ...rest } = row as Obj;
    return rest;
  });
  if (!transactions.length) throw new Error("Choose transactions to import.");
  const result = (await lib.send("transactions-import", {
    accountId, transactions, isPreview: false,
  } as never)) as { errors?: { message: string }[]; added?: unknown[]; updated?: unknown[] };
  if (result.errors?.length) throw new Error(result.errors.map((e) => e.message).join("; "));
  // Remember this account's choices, as Actual's import dialog does.
  const prefs: Obj = {};
  if (type === "csv") {
    if (settings.mapping) prefs[`csv-mappings-${accountId}`] = JSON.stringify(settings.mapping);
    if (settings.delimiter) prefs[`csv-delimiter-${accountId}`] = settings.delimiter;
    if (settings.hasHeaderRow !== undefined) prefs[`csv-has-header-${accountId}`] = String(settings.hasHeaderRow);
  }
  if ((type === "csv" || type === "qif") && settings.dateFormat) prefs[`parse-date-${accountId}-${type}`] = settings.dateFormat;
  if (settings.flipAmount !== undefined) prefs[`flip-amount-${accountId}-${type}`] = String(settings.flipAmount);
  if (Object.keys(prefs).length) await savePrefs(prefs as never);
  return { added: result.added?.length ?? 0, updated: result.updated?.length ?? 0 };
}
