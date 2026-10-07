#!/bin/sh
# Xcode Cloud post-clone step: prepares what scripts/xcode-build-engine.sh needs.
# The runner has neither Node nor an Actual checkout, so install Node, clone
# Actual at the pinned revision next to this repository, and install only the
# packages the engine bundle uses.
set -eu

repository="${CI_PRIMARY_REPOSITORY_PATH}"
actual="${CI_WORKSPACE_PATH}/actual"
tools="${CI_WORKSPACE_PATH}/engine-tools"

brew install node
node="$(brew --prefix)/bin/node"
npm="$(brew --prefix)/bin/npm"

commit="$(plutil -extract commit raw "${repository}/Engine/upstream.json")"
git init -q "${actual}"
git -C "${actual}" remote add origin https://github.com/actualbudget/actual.git
git -C "${actual}" fetch -q --depth 1 origin "${commit}"
git -C "${actual}" checkout -q FETCH_HEAD

# loot-core's dependencies and peggy; the full monorepo install is ~5x larger.
cd "${actual}"
"${node}" "$(sed -n 's/^yarnPath: //p' .yarnrc.yml)" workspaces focus \
  @actual-app/core @actual-app/vite-plugin-peggy

# Actual gets esbuild only through Storybook, so install the version its
# lockfile resolves and expose it through NODE_PATH.
esbuild="$("${node}" -e '
const lock = require("fs").readFileSync("yarn.lock", "utf8");
const versions = [...lock.matchAll(/^"esbuild@npm:[^\n]*\n  version: (\S+)/gm)].map((m) => m[1]);
console.log(versions.sort((a, b) => a.localeCompare(b, undefined, { numeric: true })).pop());
')"
"${npm}" install --no-save --no-package-lock --prefix "${tools}" "esbuild@${esbuild}"

cat > "${repository}/.xcode.env.local" <<EOF
export NODE_BINARY="${node}"
export ACTUAL_SOURCE="${actual}"
export NODE_PATH="${tools}/node_modules"
EOF
