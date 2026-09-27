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
  Native/Models.swift Native/Core/*.swift Tests/Support/BudgetSnapshot.swift Tests/EngineSmoke.swift Tests/EngineReconciliation.swift \
  Tests/EngineTransfers.swift Tests/EngineBudgetDeletion.swift \
  -module-cache-path "${project_root}/.build/ModuleCache" \
  -lsqlite3 -o .build/engine-smoke
.build/engine-smoke "${project_root}/Native/Resources"

xcrun swiftc -parse-as-library \
  Native/Models.swift Native/Core/*.swift Tests/Support/BudgetSnapshot.swift Tests/EngineRecovery.swift \
  -module-cache-path "${project_root}/.build/ModuleCache" \
  -lsqlite3 -o .build/engine-recovery
.build/engine-recovery "${project_root}/Native/Resources"

xcrun swiftc -parse-as-library \
  Native/Models.swift Native/AppModel.swift Native/Core/*.swift Tests/OptimisticEdits.swift \
  -module-cache-path "${project_root}/.build/ModuleCache" \
  -lsqlite3 -o .build/optimistic-edits
.build/optimistic-edits "${project_root}/Native/Resources"
