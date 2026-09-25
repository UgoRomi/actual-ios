#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The Xcode build bundles Actual's engine first; see scripts/xcode-build-engine.sh.
cd "${project_root}"
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
