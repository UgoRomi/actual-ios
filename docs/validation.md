# Validation

Validated on 2026-09-17 with Actual 26.9.0, commit `5bb7d6f6fdae21cb35425a3d444f83bcc74a2eef`, Xcode 27, and iPhone 17 Pro simulator running iOS 26. All data used was disposable test/demo data.

## Completed checks

- Strict TypeScript checking of the bridge and adapters against the pinned core declarations.
- Native Swift engine smoke harness: SQLite binding, exact integers, Unicode handling, rollback, transient import cleanup, sandbox path checks, PBKDF2 known vector and AES-GCM round trip.
- Recovery regression: deterministic replay discard produces a warning, blocks writes, and retains both behaviors across recreated engine lifetimes.
- Real Actual demo: transaction creation/edit/deletion, exact account balances, category allocation, and reopening with another runtime.
- Failed budget download restores the previous usable budget; the connection form stays mounted during recovery. Draft retention was checked in code, not by a separate UI failure test.
- Untracked upstream load-time cloud uploads are disabled by the adapter. Due snapshot uploads are awaited inside tracked sync, now coordinated by the native app on opening and after edits. As upstream does, a failed snapshot upload does not fail sync; it retries on the next due sync.
- Incorrect server and encryption passwords are rejected; retrying with the correct passwords succeeds.
- An existing rule that turns a new native entry into a transfer creates both reciprocal entries and exact account balances; linked transfer editing/deletion remains blocked.
- Encrypted sync integration: new temporary server and encrypted upstream fixture; native download/add/sync; offline edit in a second process; third-process reopen/sync; upstream API verifies `-2345` cents and resulting `97655`-cent account balance.
- Signed simulator build and XCTest UI smoke: welcome → real demo → Budget → Accounts → Transactions → new transaction sheet.
- Visual inspection of five light-appearance screens and the budget screen in dark appearance. The budget name was moved into scroll content after a toolbar label truncated it.

The first unsigned simulator run exposed a Keychain entitlement failure. Local ad hoc signing resolved it while keeping production Keychain access enabled. Resources are packaged under `Engine/Resources` to avoid an app-bundle metadata collision with a top-level `Resources` directory.

## Reproduce

Run `./scripts/test-engine.sh`, `node Engine/typecheck.mjs`, and `./scripts/test-sync.sh` as described in the README. The sync script retains its temporary fixture and server log for inspection and terminates only its own server process.

Use a fresh simulator because the test starts on the welcome screen and creates a demo. List available simulators with `xcrun simctl list devices available`, then use an iOS 26-or-later device identifier:

```sh
node Engine/build.mjs
xcodebuild test \
  -project ActualNative.xcodeproj \
  -scheme ActualNative \
  -destination 'platform=iOS Simulator,id=YOUR-SIMULATOR-UUID' \
  -derivedDataPath DerivedData \
  -resultBundlePath .build/UITests.xcresult \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

Choose a new result bundle path if one already exists. UI tests use only the app's demo budget. Screenshot attachments are stored in the `.xcresult` bundle.

## Remaining validation

Physical-device installation, device lock/unlock behavior, multi-device conflict stress, large-budget performance on physical devices, interrupted migrations, accessibility testing with VoiceOver/maximum Dynamic Type, all-screen dark appearance coverage, other authentication/server error modes, and App Store distribution are not yet verified end to end.

The bridge is intentionally pinned. Upgrading Actual or expanding server/authentication support requires repeating the data durability and encrypted sync checks. This is a development client, not a claim of complete parity with Actual's web app.

Screenshots are in [docs/screenshots](screenshots/): welcome, budget, accounts, transactions, entry, and dark budget.

## Review

UI, engine, and final integration reviews completed with no remaining material findings in their reviewed scopes. Regression fixes cover acknowledged-save durability, linked transfers from rules, stable Keychain identity, transient database cleanup, persistent sync-discard warnings, failed-download restoration, and explicit snapshot uploads.

## Large transaction register regression (2026-09-24)

The supplied SQLite fixture passed `PRAGMA quick_check` and contained 9,466 active transactions across 2,408 visible dates. The previous SwiftUI section closure filtered and sorted the entire register again for every date, blocking the main thread. Sections now filter/group once per view update and sort only the date keys; searches reuse one amount formatter and short-circuit text matches.

Run the standalone regression without the Actual checkout or simulator:

```sh
./scripts/test-transactions.sh
# Optional local SQLite fixture; opened read-only, never printed or modified:
./scripts/test-transactions.sh /absolute/path/to/db.sqlite --baseline
```

Checks cover newest-first dates, stable same-day order, account scoping, hidden split children, visible split parents/transfers, empty results, payee/category/notes searches, and positive/negative amounts with US/Italian locales and EUR/no currency. A synthetic 10,000-transaction/10,000-date fixture guards against testing only a few date sections. No private budget data is committed.

On the supplied fixture, the macOS Swift debug harness measured 10.777 seconds for the old per-section preparation versus 0.008 seconds for grouping and 0.047 seconds for a full no-match search. The synthetic fixture took 0.023 seconds to group and 0.050 seconds to search. These measure data preparation, not total screen presentation time. The signed iOS simulator build passed.

The opt-in UI test `testLargeBudgetTransactionsStayResponsive` requires a disposable simulator with a local budget named `Large Budget Regression`. Install the app, use `xcrun simctl get_app_container SIMULATOR_ID com.ugoromi.actualnative data` to locate its data directory, and place a **copy** of the database at `Library/Application Support/ActualNative/large-regression/db.sqlite`. Beside it, create `metadata.json` containing only `{"id":"large-regression","budgetName":"Large Budget Regression"}`. Run only that test with `-parallel-testing-enabled NO` so XCTest uses the prepared simulator, rather than an unseeded clone:

```sh
xcodebuild test -project ActualNative.xcodeproj -scheme ActualNative \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -derivedDataPath DerivedData -parallel-testing-enabled NO \
  -only-testing:ActualNativeUITests/ActualNativeUITests/testLargeBudgetTransactionsStayResponsive \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

The test opens Transactions, scrolls, opens/cancels the editor, searches and clears the query. It passed with a disposable copy of the supplied database on the iPhone 17 Pro / iOS 26.0 simulator. It skips when the fixture is absent. Use a fresh simulator for the separate demo smoke test, and delete the disposable fixture simulator after testing.

## Manual bank sync (2026-09-24)

Run `./scripts/test-bank-sync.sh`. This compiles the real JavaScriptCore bridge and native app model, creates a disposable budget, and serves simulated GoCardless/SimpleFIN responses over localhost. It uses no live bank credentials and removes its fixture after the run.

Verified: only selected linked/open accounts reach the provider; empty, unlinked, closed, deleted, invalid, and incomplete connections cannot accidentally trigger a full sync. SimpleFIN uses one batch request, including for a single selected account. Imports preserve exact cents and cleared state, run existing rules, respect pending/notes preferences, and do not duplicate on repeated refresh. Successful imports remain visible during partial failures. Rate limits, expired authorization/server tokens, missing data, retries, overlapping-command guards, and persisted balances/status/last-refresh timestamps are covered. Missing credentials and existing recovery warnings prevent bank requests.

Strict bridge type checking, the signed simulator build, native engine/recovery tests, 10,000-transaction regression, and encrypted budget-sync integration also passed. The latter still verifies offline edits and rule-created transfers through the upstream Actual API. Bank imports and connection-status changes now request asynchronous budget sync through the native coordinator; untracked upstream sync timers remain disabled.

The optional `testBankRefreshRequiresConnection` UI test uses a local budget named `Bank Sync Regression` with fake linked accounts and no server credentials. After running the bank test script, create its fixture in an empty directory:

```sh
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/actual-bank-ui.XXXXXX")"
.build/engine-bank-sync Native/Resources "${fixture_dir}" unused seed-ui
```

Install the app on a **fresh disposable simulator**. Use `xcrun simctl get_app_container SIMULATOR_ID com.ugoromi.actualnative data` to find its data directory, and copy `${fixture_dir}/bank-sync-regression` into `Library/Application Support/ActualNative/`. Do not copy `test-settings.json`; simulator credentials stay empty. Run only this test with `-parallel-testing-enabled NO`:

```sh
xcodebuild test -project ActualNative.xcodeproj -scheme ActualNative \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -derivedDataPath DerivedData -parallel-testing-enabled NO \
  -only-testing:ActualNativeUITests/ActualNativeUITests/testBankRefreshRequiresConnection \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

The fixture test passed on iPhone 17 Pro / iOS 26.0: pull-to-refresh on Accounts and an individual register, a visible connection error/retry, and continued access to transactions. Screenshots of both error states were visually checked. The test uses an explicit drag within the list because XCTest's application-wide swipe did not activate the refresh control. It skips without its fixture. The demo navigation test also passed on a separate fresh simulator session; it exercises local refresh of unlinked accounts.

Live provider connections, provider-specific reauthorization flows, and bank-sync UI on a physical device remain unverified. The timeout allowance follows upstream's five-minute SimpleFIN batch limit; that full-duration timeout was not exercised.

## Automatic budget sync (2026-09-24)

Run `./scripts/test-auto-sync.sh` with the pinned upstream core/API/server artifacts built as described in the README. It compiles the real JavaScriptCore bridge and native app model, creates an encrypted disposable budget on a temporary Actual server, and uses a local proxy to hold or reject sync responses. Temporary data and server logs are retained for inspection; the fixture shuts down its own processes.

Verified:

- Cold launch and foreground return wait for sync and snapshot refresh before allowing edits. Incoming encrypted remote changes appear in the opened budget. Duplicate activation notifications do not resync.
- Transaction additions, edits, deletions, and category allocations save locally while a previous sync response is held. Follow-up changes coalesce, requests never overlap, and the upstream API verifies exact amounts and allocations.
- A failed automatic sync preserves the completed local edit and last successful sync time, with a separate sync error. Offline opening remains usable. The edit survives engine recreation; returning to the foreground exchanges both offline and remote changes.
- Budget switching waits for active sync and resets its status. Local/demo edits and foreground returns make no server sync requests.

The incoming-message test exposed an encryption-adapter mismatch: encrypted CRDT metadata contains raw IV/tag buffers, whereas file downloads provide base64 strings. The adapter now handles both formats. Existing encrypted download, offline-restart, recovery, transfer, and bank-import regressions also pass, as does strict bridge type checking.

The signed iPhone 17 Pro / iOS 26.0 simulator build and demo UI smoke passed. The UI test also backgrounds and reactivates the app with an unfinished transaction, verifying that the sheet and payee draft remain intact. The opening-sync gate is verified with delayed responses in the native integration harness; the UI draft test uses a local demo budget.

No periodic closed-app sync or iOS background-task service is implemented. Completion while iOS suspends the app, physical-device lifecycle behavior, and live provider/server deployment behavior remain unverified. Saved edits retry on the next opening, edit, or explicit **Sync now**.

## Review fixes (2026-09-24)

A review against the pinned upstream source found four bridge defects. Each has a regression test that fails on the previous code:

- **Tracking budgets.** Opening a tracking budget failed because it has no to-budget amount, and its budgeted total was negated as if it were an envelope budget. The snapshot now reports the budget type. Tracking budgets show projected savings for the current and future months, and saved or overspent for past months, as Actual's mobile web app does. `./scripts/test-engine.sh` switches the demo to tracking and checks both summaries, the positive budgeted total, and projected savings equal to budgeted income minus budgeted expenses. A simulator screenshot of a tracking demo was inspected.
- **Changed-field edits.** Saving a transaction rewrote every column, so an edit could overwrite another device's unsynced change to a different field, or restore a transaction deleted elsewhere. Edits now send only changed fields through `transactions-batch-update`, like Actual's editors. An unchanged save writes nothing. Off-budget transactions are saved without a category, as upstream does. `./scripts/test-auto-sync.sh` edits a note through the upstream API while this device changes the amount offline. It then verifies that both changes survive sync.
- **Mutation serialization.** Updates and deletes were wrapped in a second `runMutator`, which let queued mutations, such as incoming sync changes, run concurrently. They now call the mutator handler once, under Actual's own lock.
- **Snapshot upload failures.** A rejected weekly snapshot upload failed every sync, and the error showed as "[object Object]" because upstream throws plain objects. The upload is still awaited within tracked sync, but its failure is logged and retried on the next due sync. Plain-object errors now show their reason. The automatic-sync harness rejects a due upload and verifies that sync still succeeds, that the upload date does not advance, and that the next sync uploads successfully.

Strict bridge type checking, native engine/recovery tests, encrypted budget sync, bank-sync regressions, the 10,000-transaction regression, the signed simulator build, and the demo UI smoke test on a new iPhone 17 Pro simulator also passed.
