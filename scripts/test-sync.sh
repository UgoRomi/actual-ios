#!/usr/bin/env bash
set -euo pipefail

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
xcrun swiftc -parse-as-library Native/Models.swift Native/Core/*.swift Tests/EngineSync.swift \
  -module-cache-path "${project_root}/.build/ModuleCache" -lsqlite3 -o .build/engine-sync

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/actual-native-sync.XXXXXX")"
test_port="$(node -e 'const s=require("node:net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
export NATIVE_TEST_SERVER="http://127.0.0.1:${test_port}"
server_pid=""
mkdir -p "${test_dir}/server"
cleanup() {
  if [[ -n "${server_pid}" ]]; then
    kill -CONT "${server_pid}" 2>/dev/null || true
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
  fi
  echo "Disposable test data and logs: ${test_dir}"
}
trap cleanup EXIT
ACTUAL_DATA_DIR="${test_dir}/server" ACTUAL_PORT="${test_port}" ACTUAL_HOSTNAME=127.0.0.1 \
  NODE_ENV=production node "${ACTUAL_SOURCE}/packages/sync-server/build/app.js" \
  > "${test_dir}/server.log" 2>&1 &
server_pid=$!
ready=false
for attempt in {1..100}; do
  if ! kill -0 "${server_pid}" 2>/dev/null; then cat "${test_dir}/server.log" >&2; exit 1; fi
  if rg -q "Listening on 127.0.0.1:${test_port}" "${test_dir}/server.log"; then ready=true; break; fi
  sleep 0.1
done
if [[ "${ready}" != true ]]; then echo 'Test server did not start' >&2; exit 1; fi
node Tests/sync-fixture.cjs "${test_dir}/fixture" create
.build/engine-sync Native/Resources "${test_dir}/native" "${test_dir}/fixture/fixture.json" download
kill -STOP "${server_pid}"
.build/engine-sync Native/Resources "${test_dir}/native" "${test_dir}/fixture/fixture.json" offline
kill -CONT "${server_pid}"
.build/engine-sync Native/Resources "${test_dir}/native" "${test_dir}/fixture/fixture.json" sync
node Tests/sync-fixture.cjs "${test_dir}/fixture" verify
