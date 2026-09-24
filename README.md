# Actual Native

An unofficial SwiftUI iOS client for Actual Budget. A separate app with native Liquid Glass navigation, Actual purple and navy, and the real Actual engine running locally through JavaScriptCore.

This is a development build, with no App Store submission or distribution signing configured.

## What works

- Open a real demo or download a budget from your Actual server.
- Browse monthly budgets, adjust category allocations, and see account balances.
- Search transactions; add, edit, categorize, clear, and delete ordinary transactions.
- Reopen and edit downloaded budgets offline. **Settings → Sync now** sends and receives changes explicitly.
- Open end-to-end encrypted budgets using their encryption password.
- Native light/dark appearances, system glass controls, and locale-aware integer-cent entry.

Transfers, splits, and reconciled transactions are view only. Account/category creation, reconciliation, bank setup, reports, schedules/rule editors, widgets, and Shortcuts remain in Actual web/desktop. Existing Actual transaction rules still run through its engine.

Server connection supports password authentication and one server per installation. Use HTTPS with a valid certificate; HTTP is allowed only for localhost development. OpenID Connect, custom certificate trust, and automatic/background sync are not implemented. Your server password and budget encryption password are separate.

The budget's default currency code is used when present; otherwise amounts have no currency symbol. Separators follow the device locale and amounts always show two decimals. Other Actual formatting preferences are not yet mirrored.

## Build

Requires macOS, Xcode with the iOS 26 SDK or later, Node 22+, and Yarn 4. Tested with Xcode 27 and an iOS 26 simulator. The deployment target is iOS 26.

The build consumes a separate Actual checkout, by default `../actual`. Its exact tested revision is recorded in [Engine/upstream.json](Engine/upstream.json); the build rejects a different commit. Use a dedicated checkout for that revision if your main Actual checkout has advanced.

[AGENTS.md](AGENTS.md) instructs coding agents to consult that checkout's web UI and core logic before changing related native behavior.

In the Actual checkout, install dependencies:

```sh
yarn install --immutable
```

In this project:

```sh
./scripts/build.sh
open ActualNative.xcodeproj
```

Select the `ActualNative` scheme and an iOS simulator, then Run. The script bundles Actual and copies its database template, migrations, and license notices before building. If the checkouts are not siblings, prefix commands with `ACTUAL_SOURCE=/absolute/path/to/actual`.

Simulator builds use local ad hoc signing so Keychain works. For an iPhone, choose your development team and a unique bundle identifier in Xcode, and enable automatic signing. Device installation has not yet been verified.

## Check the engine

The following executable test creates only disposable local budgets:

```sh
./scripts/test-engine.sh
```

For strict bridge type checking and the encrypted sync integration test, first run these commands from the Actual checkout root:

```sh
yarn workspace @actual-app/core build
yarn workspace @actual-app/api build
yarn workspace @actual-app/sync-server build
```

Then, from this project:

```sh
node Engine/typecheck.mjs
./scripts/test-sync.sh
```

The sync test starts a temporary server on a free localhost port, downloads an encrypted fixture, adds a transaction, pauses the server, edits in a fresh process, and verifies the next process can sync the exact amount and balance back to Actual's upstream API. It stops its server and prints the disposable data/log location.

Simulator UI checks are in `Tests/UITests`. See [docs/validation.md](docs/validation.md) for the command and observed coverage.

Run `./scripts/test-transactions.sh` for register grouping/search regressions and a 10,000-transaction fixture. Optionally pass a local `db.sqlite` path to test it read-only, with `--baseline` to compare the previous section-preparation cost. See the validation notes for the opt-in large-budget simulator test.

## Implementation and storage

SwiftUI owns the visible UI. `Engine/entry.ts` exposes a small command interface to Actual's pinned handlers. `Native/Core` supplies SQLite, sandboxed files, URLSession HTTP, cryptography, timers, and a serial JavaScriptCore runtime. The engine is the sole budget writer; amounts cross the bridge as exact integer cents.

Downloaded budget data is stored locally as SQLite in the app sandbox, using iOS data protection; the local database is not separately encrypted by this app. Server tokens and imported encryption keys are in Keychain. Actual's optional end-to-end encryption protects synced budget data using its existing format. The app never sends data to a separate intermediary service.

Future upstream revisions require adapter review and rerunning the integration checks. Newer-schema changes that cannot be applied trigger an update warning and block edits. If Actual discards a deferred change, this build retains a warning and blocks further writes to that local budget; a repair/acknowledgment workflow is not yet provided. Keep a backup before trying this development client with a real budget.

Actual Budget and bundled dependencies retain their original licenses. The build includes `Actual-LICENSE.txt` and `ThirdPartyNotices.txt` in its resources. This project is unofficial and is not an Actual Budget release.
