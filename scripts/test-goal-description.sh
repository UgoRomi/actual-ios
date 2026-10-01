#!/usr/bin/env bash
# Evaluates described targets against Apple's on-device model. Needs a Mac with
# Apple Intelligence turned on; otherwise it reports SKIP.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${project_root}"
mkdir -p .build
xcrun swiftc -parse-as-library -swift-version 6 \
  Native/Models.swift Native/Schedules.swift Native/Rules.swift Native/Importing.swift Native/Targets.swift Native/Reports.swift \
  Native/GoalDescription.swift Native/Core/*.swift Tests/GoalDescriptionEvaluation.swift \
  -module-cache-path "${project_root}/.build/ModuleCache" \
  -lsqlite3 -o .build/goal-description
.build/goal-description
