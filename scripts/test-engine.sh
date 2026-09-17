#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ACTUAL_SOURCE="${ACTUAL_SOURCE:-${project_root}/../actual}"

if [[ ! -f "${ACTUAL_SOURCE}/package.json" ]]; then
  echo "Actual source checkout not found at ${ACTUAL_SOURCE}" >&2
  exit 1
fi

cd "${project_root}"
node Engine/build.mjs
mkdir -p .build
xcrun swiftc -parse-as-library \
  Native/Models.swift Native/Core/*.swift Tests/EngineSmoke.swift \
  -module-cache-path "${project_root}/.build/ModuleCache" \
  -lsqlite3 -o .build/engine-smoke
.build/engine-smoke "${project_root}/Native/Resources"
