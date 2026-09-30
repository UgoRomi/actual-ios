#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ACTUAL_SOURCE="${ACTUAL_SOURCE:-${project_root}/../actual}"
cd "${project_root}"
node Engine/build.mjs
mkdir -p .build
xcrun swiftc -parse-as-library Native/Models.swift Native/Schedules.swift Native/Rules.swift Native/Importing.swift Native/Targets.swift Native/Reports.swift Native/AppModel.swift Native/Core/*.swift Tests/Support/*.swift Tests/AutomaticBudgetSync.swift \
  -module-cache-path "${project_root}/.build/ModuleCache" -lsqlite3 -o .build/automatic-budget-sync
node Tests/automatic-sync-fixture.mjs
