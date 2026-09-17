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
xcodebuild \
  -project ActualNative.xcodeproj \
  -scheme ActualNative \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY=- \
  "$@" \
  build
