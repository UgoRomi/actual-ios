import { Buffer } from "buffer";

import { native } from "../native";
export function randomBytes(size: number) {
  return Buffer.from(native<string>("crypto.random", { size }), "base64");
}
export function randomFillSync<T extends Uint8Array>(value: T) {
  value.set(randomBytes(value.length));
  return value;
}
export function createHash(algorithm: string) {
  const chunks: Uint8Array[] = [];
  return {
    update(value: string | Uint8Array) {
      chunks.push(typeof value === "string" ? Buffer.from(value) : value);
      return this;
    },
    digest(encoding?: string) {
      const data = native<string>("crypto.hash", {
        algorithm,
        data: Buffer.concat(chunks).toString("base64"),
      });
      const value = Buffer.from(data, "base64");
      return encoding === "hex" ? value.toString("hex") : value;
    },
  };
}
export default { randomBytes, randomFillSync, createHash };
