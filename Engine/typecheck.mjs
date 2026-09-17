import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const upstream = path.resolve(process.env.ACTUAL_SOURCE || path.join(root, "../actual"));
const types = path.join(upstream, "packages/loot-core/@types/src");
if (!fs.existsSync(path.join(types, "server/main.d.ts")))
  throw new Error("Run yarn workspace @actual-app/core build from the Actual checkout first.");
const mappings = {
  "@actual/core": "server/main.d.ts",
  "@actual/prefs": "server/prefs.d.ts",
  "@actual/server-config": "server/server-config.d.ts",
  "@actual/sync": "server/sync/index.d.ts",
  "@actual/source/*.ts": "*.d.ts",
  "#server/aql": "server/aql/index.d.ts",
  "#server/db": "server/db/index.d.ts",
  "#server/encryption": "server/encryption/index.d.ts",
  "#server/sync": "server/sync/index.d.ts",
  "#types/models": "types/models/index.d.ts",
  "#*": "*.d.ts",
};
const paths = Object.fromEntries(
  Object.entries(mappings).map(([key, value]) => [key, [path.join(types, value)]]),
);
const packageImports = JSON.parse(
  fs.readFileSync(path.join(upstream, "packages/loot-core/package.json"), "utf8"),
).imports;
for (const [key, target] of Object.entries(packageImports)) {
  const source = typeof target === "string" ? target : target.api || target.default;
  if (typeof source === "string" && source.startsWith("./src/"))
    paths[key] = [path.join(types, source.slice(6).replace(/\.tsx?$/, ".d.ts"))];
}
paths["@actual/storage"] = [path.join(root, "Engine/adapters/storage.ts")];
paths["buffer"] = [path.join(upstream, "node_modules/buffer/index.d.ts")];
const config = {
  compilerOptions: {
    strict: true,
    noEmit: true,
    skipLibCheck: true,
    target: "ES2022",
    module: "ESNext",
    moduleResolution: "Bundler",
    allowImportingTsExtensions: true,
    lib: ["ES2022", "DOM"],
    types: ["node"],
    typeRoots: [path.join(upstream, "node_modules/@types")],
    paths,
  },
  include: [path.join(root, "Engine/**/*.ts")],
};
const configPath = path.join(root, ".build/tsconfig.engine.json");
fs.mkdirSync(path.dirname(configPath), { recursive: true });
fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
execFileSync(path.join(upstream, "node_modules/.bin/tsgo"), ["-p", configPath], {
  stdio: "inherit",
});
