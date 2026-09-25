#!/usr/bin/env bash
# Xcode build phase: bundles Actual's engine into Native/Resources before the
# app copies it, so a build never ships an engine older than its Swift code.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Xcode opened from the Dock does not see your shell's variables or PATH.
# This optional, untracked file can set NODE_BINARY and ACTUAL_SOURCE.
if [[ -f "${project_root}/.xcode.env.local" ]]; then source "${project_root}/.xcode.env.local"; fi

export ACTUAL_SOURCE="${ACTUAL_SOURCE:-${project_root}/../actual}"
if [[ ! -f "${ACTUAL_SOURCE}/package.json" ]]; then
  echo "error: Actual checkout not found at ${ACTUAL_SOURCE}. Set ACTUAL_SOURCE in .xcode.env.local; see README.md." >&2
  exit 1
fi

supported() {
  [[ -n "$1" && -x "$1" ]] && "$1" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)' 2>/dev/null
}
# nvm selects its default Node when loaded.
nvm_node() { (set +eu; source "${NVM_DIR:-$HOME/.nvm}/nvm.sh" >/dev/null 2>&1; command -v node) || true; }

if [[ -n "${NODE_BINARY:-}" ]]; then
  candidates=("${NODE_BINARY}")
else
  candidates=("$(command -v node || true)")
  if [[ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]]; then candidates+=("$(nvm_node)"); fi
  candidates+=(/opt/homebrew/bin/node /usr/local/bin/node "${HOME}/.volta/bin/node")
fi
node=""
for candidate in "${candidates[@]}"; do
  if supported "${candidate}"; then node="${candidate}"; break; fi
done
if [[ -z "${node}" ]]; then
  echo "error: Node 22 or later not found. Set NODE_BINARY in .xcode.env.local; see README.md." >&2
  exit 1
fi

"${node}" "${project_root}/Engine/build.mjs"
