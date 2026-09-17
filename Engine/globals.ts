import { Buffer } from "buffer";
export { Buffer };
export const process = {
  env: { NODE_ENV: "production" },
  nextTick: (fn: () => void) => Promise.resolve().then(fn),
  cwd: () => "/documents",
  platform: "ios",
  version: "v24.0.0",
  browser: true,
};
export const global = globalThis;
