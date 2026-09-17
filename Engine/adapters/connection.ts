import { native } from "../native";
export function init() {}
export function send(type: string, args: unknown) {
  native("event", { type, args });
}
export function getNumClients() {
  return 1;
}
export function resetEvents() {}
