import { Buffer } from "buffer";

import { native } from "../native";
import { sqlFunctions } from "../sql-functions";
declare function _registerSQL(db: number, name: string, arity: number, fn: unknown): void;
type Database = { id: number; depth: number };
type Statement = { db: Database; sql: string };
export async function init() {}
export function setWasmBinary() {}
export function openDatabase(input: string | Uint8Array): Database {
  const id = native<number>(
    "sql.open",
    typeof input === "string" ? { path: input } : { data: Buffer.from(input).toString("base64") },
  );
  for (const [name, fn] of Object.entries(sqlFunctions)) _registerSQL(id, name, fn.length, fn);
  return { id, depth: 0 };
}
export function closeDatabase(db: Database) {
  native("sql.close", { id: db.id });
}
export function prepare(db: Database, sql: string): Statement {
  return { db, sql };
}
export function runQuery<T>(
  db: Database,
  sql: string | Statement,
  params: unknown[] = [],
  fetchAll = false,
): T {
  const query = { id: db.id, sql: typeof sql === "string" ? sql : sql.sql, params, fetchAll };
  if (!fetchAll) return native<T>("sql.query", query);
  // Rows arrive as values in SQLite's column order, as better-sqlite3 returns them:
  // upstream reads some results, such as an AQL calculation, from the first column.
  const { columns, rows } = native<{ columns: string[]; rows: unknown[][] }>("sql.query", {
    ...query,
    ordered: true,
  });
  return rows.map((values) => {
    const row: Record<string, unknown> = {};
    columns.forEach((column, index) => {
      row[column] = values[index];
    });
    return row;
  }) as T;
}
export function execQuery(db: Database, sql: string) {
  native("sql.exec", { id: db.id, sql });
}
export function transaction<T>(db: Database, fn: () => T): T {
  const name = "native_sp_" + db.depth++;
  execQuery(db, "SAVEPOINT " + name);
  try {
    const result = fn();
    execQuery(db, "RELEASE " + name);
    return result;
  } catch (error) {
    execQuery(db, "ROLLBACK TO " + name);
    execQuery(db, "RELEASE " + name);
    throw error;
  } finally {
    db.depth--;
  }
}
export async function asyncTransaction<T>(db: Database, fn: () => Promise<T>): Promise<T> {
  if (db.depth > 0) return fn();
  db.depth++;
  execQuery(db, "BEGIN");
  try {
    return await fn();
  } finally {
    try {
      execQuery(db, "COMMIT");
    } finally {
      db.depth--;
    }
  }
}
export async function exportDatabase(db: Database) {
  return Buffer.from(native<string>("sql.export", { id: db.id }), "base64");
}
