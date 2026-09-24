import { execFileSync } from "node:child_process";
import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const upstream = path.resolve(process.env.ACTUAL_SOURCE || path.join(root, "../actual"));
const require = createRequire(path.join(upstream, "package.json"));
const { build } = require("esbuild");
const peggy = require("peggy");
const core = path.join(upstream, "packages/loot-core");
const adapters = path.join(root, "Engine/adapters");
const overrides = {
  "#server/cloud-storage": "cloud-storage.ts",
  "#platform/server/sqlite": "sqlite.ts",
  "#platform/server/fs": "fs.ts",
  "#platform/server/asyncStorage": "storage.ts",
  "#platform/server/fetch": "fetch.ts",
  "#platform/server/connection": "connection.ts",
  "#platform/server/memory": "memory.ts",
  "#server/encryption/encryption-internals": "encryption.ts",
  "#shared/platform": "platform.ts",
  "#platform/server/indexeddb": "indexeddb.ts",
};
const aliases = {
  path: "path-browserify",
  stream: "stream-browserify",
  events: "events/",
  util: "util/",
  timers: "timers-browserify",
  buffer: "buffer/",
};
const revision = execFileSync("git", ["rev-parse", "HEAD"], {
  cwd: upstream,
  encoding: "utf8",
}).trim();
const pinPath = path.join(root, "Engine/upstream.json");
if (fs.existsSync(pinPath)) {
  const pin = JSON.parse(fs.readFileSync(pinPath, "utf8"));
  if (pin.commit !== revision)
    throw new Error(
      "Actual checkout differs from the tested revision " +
        pin.commit +
        ". Use a checkout at that commit.",
    );
}
const out = path.join(root, "Native/Resources");
fs.mkdirSync(out, { recursive: true });
const result = await build({
  entryPoints: [path.join(root, "Engine/entry.ts")],
  outfile: path.join(out, "engine.js"),
  bundle: true,
  format: "iife",
  globalName: "ActualBridge",
  platform: "browser",
  target: "safari18",
  conditions: ["api", "browser"],
  nodePaths: [path.join(upstream, "node_modules")],
  inject: [path.join(root, "Engine/globals.ts")],
  define: {
    "process.env.NODE_ENV": '"production"',
    "process.env.IS_DEV": '"false"',
    "process.env.PUBLIC_URL": '"/resources/"',
  },
  plugins: [
    {
      name: "actual-native",
      setup(b) {
        b.onResolve({ filter: /.*/ }, (args) => {
          if (overrides[args.path]) return { path: path.join(adapters, overrides[args.path]) };
          if (
            args.path === "./backups" &&
            args.importer === path.join(core, "src/server/budgetfiles/app.ts")
          )
            return { path: path.join(adapters, "backups.ts") };
          if (args.path === "node:crypto" || args.path === "crypto")
            return { path: path.join(adapters, "node-crypto.ts") };
          if (args.path === "@actual/core") return { path: path.join(core, "src/server/main.ts") };
          if (args.path === "@actual/prefs")
            return { path: path.join(core, "src/server/prefs.ts") };
          if (args.path === "@actual/server-config")
            return { path: path.join(core, "src/server/server-config.ts") };
          if (args.path === "@actual/sync")
            return { path: path.join(core, "src/server/sync/index.ts") };
          if (args.path === "@actual/storage") return { path: path.join(adapters, "storage.ts") };
          if (args.path === "@actual/sql-functions")
            return { path: path.join(root, "Engine/sql-functions.ts") };
          if (args.path.startsWith("@actual/source/"))
            return { path: path.join(core, "src", args.path.slice(15)) };
          if (aliases[args.path]) return { path: require.resolve(aliases[args.path]) };
        });
        b.onLoad({ filter: /\.(pegjs|peggy)$/ }, async (args) => ({
          contents: peggy.generate(fs.readFileSync(args.path, "utf8"), {
            output: "source",
            format: "es",
          }),
          loader: "js",
        }));
      },
    },
  ],
  logLevel: "info",
  // Smaller source parses faster at launch. Keep names: errors and upstream
  // code may rely on function and class names.
  minify: true,
  keepNames: true,
  sourcemap: false,
  metafile: true,
});
fs.copyFileSync(path.join(core, "default-db.sqlite"), path.join(out, "default-db.sqlite"));
fs.cpSync(path.join(core, "migrations"), path.join(out, "migrations"), {
  recursive: true,
});
fs.copyFileSync(path.join(upstream, "LICENSE.txt"), path.join(out, "Actual-LICENSE.txt"));
fs.writeFileSync(
  path.join(root, "Engine/upstream.json"),
  JSON.stringify(
    {
      repository: "https://github.com/actualbudget/actual",
      commit: revision,
      version: JSON.parse(fs.readFileSync(path.join(core, "package.json"), "utf8")).version,
    },
    null,
    2,
  ) + "\n",
);

const packageRoots = new Set();
for (const input of Object.keys(result.metafile.inputs)) {
  let directory = path.dirname(path.resolve(input));
  while (directory.includes("node_modules")) {
    if (fs.existsSync(path.join(directory, "package.json"))) {
      packageRoots.add(directory);
      break;
    }
    directory = path.dirname(directory);
  }
}
let notices = "Actual Native bundles Actual Budget and the following third-party software.\n\n";
notices += fs.readFileSync(path.join(upstream, "LICENSE.txt"), "utf8") + "\n\n";
for (const directory of [...packageRoots].sort()) {
  const pkg = JSON.parse(fs.readFileSync(path.join(directory, "package.json"), "utf8"));
  const licenseFile = fs
    .readdirSync(directory)
    .find(
      (name) =>
        /^(license|licence|copying)(\.|$)/i.test(name) &&
        fs.statSync(path.join(directory, name)).isFile(),
    );
  notices += `${pkg.name} ${pkg.version} (${pkg.license || "See project license"})\n${licenseFile ? fs.readFileSync(path.join(directory, licenseFile), "utf8") : "Project: " + JSON.stringify(pkg.repository || pkg.homepage || "")}\n\n`;
}
fs.writeFileSync(path.join(out, "ThirdPartyNotices.txt"), notices);
