import { Buffer } from "buffer";
declare function _native(operation: string, argumentsJSON: string): string;
export function native<T = unknown>(operation: string, args: unknown = {}): T {
  const result = JSON.parse(_native(operation, JSON.stringify(args)));
  if (result.error) throw new Error(result.error);
  return result.value;
}
export const bytes = (value: ArrayBuffer | Uint8Array) =>
  Buffer.from(value instanceof ArrayBuffer ? new Uint8Array(value) : value).toString("base64");
export const fromBytes = (value: string) => Buffer.from(value, "base64");
