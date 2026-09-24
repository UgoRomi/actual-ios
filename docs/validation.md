# Validation

Validated on 2026-09-17 with Actual 26.9.0, commit `5bb7d6f6fdae21cb35425a3d444f83bcc74a2eef`, Xcode 27, and iPhone 17 Pro simulator running iOS 26. All data used was disposable test/demo data.

## Completed checks

- Strict TypeScript checking of the bridge and adapters against the pinned core declarations.
- Native Swift engine smoke harness: SQLite binding, exact integers, Unicode handling, rollback, transient import cleanup, sandbox path checks, PBKDF2 known vector and AES-GCM round trip.
- Recovery regression: deterministic replay discard produces a warning, blocks writes, and retains both behaviors across recreated engine lifetimes.
- Real Actual demo: transaction creation/edit/deletion, exact account balances, category allocation, and reopening with another runtime.
- Failed budget download restores the previous usable budget; the connection form stays mounted during recovery. Draft retention was checked in code, not by a separate UI failure test.
- Automatic load-time cloud uploads are disabled by the adapter. Due snapshot uploads are awaited inside explicit sync; the error path was reviewed statically.
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
