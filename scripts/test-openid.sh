#!/usr/bin/env bash
set -euo pipefail

# With --simulator ID, runs the OpenID UI test on that fresh simulator instead
# of the engine harness. Both start with a server no one has signed in to yet.
simulator=""
if [[ "${1:-}" == "--simulator" ]]; then
  simulator="${2:?Pass a simulator identifier from xcrun simctl list devices available}"
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ACTUAL_SOURCE="${ACTUAL_SOURCE:-${project_root}/../actual}"
for artifact in packages/api/dist/index.js packages/sync-server/build/app.js; do
  if [[ ! -f "${ACTUAL_SOURCE}/${artifact}" ]]; then
    echo "Build Actual core, API and sync server first; see README.md." >&2
    exit 1
  fi
done

cd "${project_root}"
node Engine/build.mjs
mkdir -p .build
xcrun swiftc -parse-as-library Native/Models.swift Native/Targets.swift Native/Reports.swift Native/AppModel.swift Native/Core/*.swift Tests/EngineOpenID.swift \
  -module-cache-path "${project_root}/.build/ModuleCache" -lsqlite3 -o .build/engine-openid

free_port() {
  node -e 'const s=require("node:net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(String(s.address().port));s.close()})'
}
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/actual-native-openid.XXXXXX")"
server_port="$(free_port)"
provider_port="$(free_port)"
export NATIVE_TEST_SERVER="http://127.0.0.1:${server_port}"
provider="http://127.0.0.1:${provider_port}"
client_id="actual-native-test"
client_secret="disposable-openid-secret"
server_pid=""
provider_pid=""
mkdir -p "${test_dir}/server"
cleanup() {
  for pid in "${server_pid}" "${provider_pid}"; do
    if [[ -n "${pid}" ]]; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
  done
  echo "Disposable test data and logs: ${test_dir}"
}
trap cleanup EXIT
wait_for() {
  local pid="$1" log="$2" message="$3"
  for attempt in {1..100}; do
    if ! kill -0 "${pid}" 2>/dev/null; then cat "${log}" >&2; exit 1; fi
    if rg -q --fixed-strings "${message}" "${log}"; then return; fi
    sleep 0.1
  done
  echo "Did not start: ${message}" >&2
  exit 1
}

node Tests/openid-provider.cjs "${provider_port}" "${client_id}" "${client_secret}" \
  "${NATIVE_TEST_SERVER}/openid/callback" > "${test_dir}/provider.log" 2>&1 &
provider_pid=$!
wait_for "${provider_pid}" "${test_dir}/provider.log" "OpenID provider listening on ${provider}"

ACTUAL_DATA_DIR="${test_dir}/server" ACTUAL_PORT="${server_port}" ACTUAL_HOSTNAME=127.0.0.1 \
  NODE_ENV=production node "${ACTUAL_SOURCE}/packages/sync-server/build/app.js" \
  > "${test_dir}/server.log" 2>&1 &
server_pid=$!
wait_for "${server_pid}" "${test_dir}/server.log" "Listening on 127.0.0.1:${server_port}"

node Tests/sync-fixture.cjs "${test_dir}/fixture" create
node Tests/openid-fixture.cjs "${test_dir}/fixture" "${provider}" "${client_id}" "${client_secret}"
if [[ -n "${simulator}" ]]; then
  TEST_RUNNER_ACTUAL_OPENID_TEST_SERVER="${NATIVE_TEST_SERVER}" \
    TEST_RUNNER_ACTUAL_OPENID_TEST_PASSWORD="$(node -p 'require(process.argv[1]).password' "${test_dir}/fixture/fixture.json")" \
    xcodebuild test -project ActualNative.xcodeproj -scheme ActualNative \
    -destination "platform=iOS Simulator,id=${simulator}" -derivedDataPath DerivedData \
    -parallel-testing-enabled NO -resultBundlePath "${test_dir}/OpenID.xcresult" \
    -only-testing:ActualNativeUITests/ActualNativeUITests/testOpenIDSignIn \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
else
  .build/engine-openid Native/Resources "${test_dir}/native" "${test_dir}/fixture/fixture.json"
fi
