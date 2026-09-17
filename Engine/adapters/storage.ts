import { native } from "../native";
let store: Record<string, unknown> = {};
export function init() {
  store = native<Record<string, unknown>>("settings.read");
}
function persist() {
  native("settings.write", store);
}
export function getItemSync(key: string) {
  return store[key];
}
export async function getItem(key: string) {
  return getItemSync(key);
}
export function setItemSync(key: string, value: unknown) {
  store[key] = value;
  persist();
}
export async function setItem(key: string, value: unknown) {
  setItemSync(key, value);
}
export async function removeItem(key: string) {
  delete store[key];
  persist();
}
export async function multiGet(keys: string[]) {
  return Object.fromEntries(keys.map((key) => [key, store[key]]));
}
export async function multiSet(entries: [string, unknown][]) {
  for (const [key, value] of entries) store[key] = value;
  persist();
}
export async function multiRemove(keys: string[]) {
  for (const key of keys) delete store[key];
  persist();
}
