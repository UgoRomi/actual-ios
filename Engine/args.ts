// Argument checks shared by the engine's commands.
import { isValidYearMonth, isValidYearMonthDay } from "@actual/source/shared/months.ts";

export type Obj = Record<string, unknown>;

export function object(value: unknown): Obj {
  if (value && typeof value === "object" && !Array.isArray(value))
    return Object.fromEntries(Object.entries(value));
  throw new Error("Expected an object");
}
export function text(value: unknown, fallback = ""): string {
  return typeof value === "string" ? value : fallback;
}
export function integer(value: unknown, message = "Invalid monetary amount"): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) throw new Error(message);
  return value;
}
export function month(value: unknown): string {
  if (typeof value !== "string" || !isValidYearMonth(value)) throw new Error("Invalid budget month");
  return value;
}
export function day(value: unknown, what = "date"): string {
  if (typeof value !== "string" || !isValidYearMonthDay(value)) throw new Error(`Choose a valid ${what}.`);
  return value;
}
export const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
