import { Buffer } from "buffer";

import { native, bytes, fromBytes } from "../native";
export { randomBytes } from "./node-crypto";
type Key = { getId(): string; getValue(): { raw: Uint8Array } };
export async function createKey({ secret, salt }: { secret: string; salt: string }) {
  const base64 = native<string>("crypto.derive", { secret, salt });
  return { raw: fromBytes(base64), base64 };
}
export async function importKey(base64: string) {
  return { raw: fromBytes(base64), base64 };
}
export async function encrypt(key: Key, value: Uint8Array) {
  const result = native<{ value: string; iv: string; authTag: string }>("crypto.encrypt", {
    key: bytes(key.getValue().raw),
    data: bytes(value),
  });
  return {
    value: fromBytes(result.value),
    meta: {
      keyId: key.getId(),
      algorithm: "aes-256-gcm",
      iv: result.iv,
      authTag: result.authTag,
    },
  };
}
export async function decrypt(
  key: Key,
  value: Uint8Array,
  meta: { algorithm: string; iv: string; authTag: string },
) {
  if (meta.algorithm !== "aes-256-gcm") throw new Error("Unsupported encryption algorithm");
  return Buffer.from(
    native<string>("crypto.decrypt", {
      key: bytes(key.getValue().raw),
      data: bytes(value),
      iv: meta.iv,
      authTag: meta.authTag,
    }),
    "base64",
  );
}
