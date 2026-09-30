#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${project_root}"
mkdir -p .build
xcrun swiftc -parse-as-library -swift-version 6 \
  Native/ThemeModel.swift Tests/Themes.swift \
  -module-cache-path "${project_root}/.build/ModuleCache" \
  -o .build/themes
.build/themes
