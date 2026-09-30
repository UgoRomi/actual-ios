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

Install the app on a **fresh disposable simulator**. Use `xcrun simctl get_app_container SIMULATOR_ID com.ugoromi.actualnative data` to find its data directory, and copy `${fixture_dir}/bank-sync-regression` into `Library/Application Support/ActualNative/`. Do not copy `settings.json` or `test-secrets.json`; simulator credentials stay empty. Run only this test with `-parallel-testing-enabled NO`:

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

## Upstream parity fixes (2026-09-24)

A second set of bridge fixes aligns behavior with the pinned upstream source. Each automated check below failed on the previous code:

- **Payees.** A typed payee name now goes through upstream's `createPayee`, which reuses an existing payee whose name differs only in case. `./scripts/test-engine.sh` saves an uppercased existing payee name and checks that no payee is added.
- **Rules on new transactions.** New transactions follow Actual's mobile editor. `rules-run` fills empty fields and may extend notes; a rule's payee always applies; otherwise the user's entries win. The transaction is then saved through `transactions-batch-update` without running rules again, and rule-created splits are kept. The engine test adds a rule that sets a category and payee. It checks that a chosen category survives, that an empty category is filled, and that the rule's payee applies. The encrypted sync test's rule-created transfer still produces reciprocal entries and exact balances.
- **Bank refresh ordering.** A server-backed budget now syncs before any bank request and syncs again after imports. `./scripts/test-auto-sync.sh` links the fixture account to a local fake GoCardless provider. It verifies that a failed budget sync stops the refresh before any bank request, and that a successful refresh orders requests as sync, bank, then sync.
- **Account balances.** Balances use `account-properties`, the same unfiltered sum Actual shows, so future-dated transactions count. The engine test adds a transaction dated a year ahead and checks the balance.
- **Backups.** Actual's desktop backup service, which made a full copy every 15 minutes, is replaced with a no-op by a build override, as in Actual's web and mobile apps. The bundled budget loader was checked to call the no-op. Existing backup files from earlier builds are left in place.
- **Bank connections.** SimpleFIN accounts no longer need an external bank ID, as with upstream's batch handler; `./scripts/test-bank-sync.sh` includes one. Requests to every bank provider's `/transactions` endpoint may now take up to five minutes instead of stopping after 30 seconds without data, and upstream applies each provider's shorter limit. A one-off run with a 35-second provider response imported successfully, and failed with the previous timeout; it is not part of the suite to keep runs fast.

Strict bridge type checking, native engine/recovery tests, encrypted budget sync, automatic sync, bank-sync regressions, the 10,000-transaction regression, the signed simulator build, and the demo UI smoke test on a new iPhone 17 Pro simulator passed.

## Opening sync, repair, search, and loading (2026-09-24)

- **Foreground sync.** Returning within five minutes of a successful sync, with no failure since, skips the opening sync. **Continue offline** releases the saved budget while the sync continues and later refreshes the view. `./scripts/test-auto-sync.sh` checks that a quick return makes no sync request. After the interval, it checks that the gate offers to continue while a response is held, and that continuing leaves the app usable. An allocation saved meanwhile reaches the upstream API once the response is released.
- **Discarded-change warning.** The warning now matches Actual's. **Keep using this budget**, after a confirmation, clears the pause and syncs, as Actual continues after this warning. Changes waiting for a newer Actual version stay blocked, because only an update can apply them. `./scripts/test-engine.sh` dismisses a reviewed warning and saves afterward. It then adds a change for a table this version lacks, and checks that it cannot be dismissed and still blocks edits.
- **Search.** Payee and category choices are searchable lists; a new payee name can be added from the search. The demo UI test adds a payee through search and finds a category by name. It then checks that both survive backgrounding. Screenshots of the editor and both pickers were inspected. The **Continue offline** button was checked in the harness, not visually.
- **Loading.** The engine bundle is minified with names kept, from 5.2 MB to 2.5 MB, and loads off the main thread. On a Mac the engine started in 63 ms instead of 80 ms; device timing was not measured. The bridge passes each result's JSON through unchanged. Separate overview, budget-month, and register requests replace the full snapshot, and results decode off the main thread. A month change or allocation reloads only the month: on the demo budget, under 1 ms instead of 8 ms for everything. Transaction edits, syncs, and bank imports still reload all three.
- **Settings storage.** Only `user-token`, `user-id`, `user-key`, and `encrypt-keys` stay in the Keychain, which is written only when they change. Other settings are in `settings.json` with file protection. The engine test migrates a store holding every setting, as earlier builds did. It then checks that ordinary changes leave the secret store untouched.
- **Formatters.** Number formatters are cached per purpose, currency, and locale, including separators; date formatters are created once.

Strict bridge type checking, native engine/recovery tests, encrypted budget sync, automatic sync, bank-sync regressions, the 10,000-transaction regression, the signed simulator build, and the demo UI test on new iPhone 17 Pro simulators passed.

## Reconciliation (2026-09-24)

`./scripts/test-engine.sh` reconciles a demo account through the native bridge and checks the database directly:

- The reported cleared balance matches the register. Clearing a split carries to its children. Clearing one side of a transfer leaves the other side unchanged.
- An adjustment covers the exact difference, is cleared, is dated today, and is created only when needed.
- A lock requested after the balance changed is refused, and nothing is locked or recorded. A balanced lock marks every cleared transaction in the account reconciled, including split children, leaves uncleared ones unlocked, and records the time.
- Reconciled transactions must be unlocked before their cleared state changes. Unlocking a split unlocks its children. Edits and deletions need confirmation for the transaction as it is now; a confirmed edit keeps it cleared and locked. Moving one to another account unlocks it.
- Exiting an unbalanced reconciliation locks nothing but records the time, as Actual does.

The recovery test checks that the new commands are blocked by a sync warning. `./scripts/test-bank-sync.sh` checks that SimpleFIN refreshes after the first record the bank's balance. It then reconciles that account through the app model: a refused lock keeps the reconciliation, an adjustment balances it, locking ends it, and closing the budget clears it.

The UI test `testDemoReconciliation` reconciles a demo account to zero: prefilled cleared balance, clearing and unclearing a row, adjustment, lock, and the warning before saving a locked transaction. It passed with the demo navigation test on a new iPhone 17 Pro / iOS 26.0 simulator, run with `-parallel-testing-enabled NO`; it opens the demo itself when needed. Screenshots of the reconcile sheet, both banner states, the locked register, and the save warning were inspected.

Strict bridge type checking, the encrypted sync, automatic sync, and 10,000-transaction regressions also passed. `./scripts/test-sync.sh` needs `rg` on `PATH`. Reconciliation against a live bank connection and on a physical device was not verified.

## Transfers (2026-09-25)

`./scripts/test-engine.sh` makes transfers between demo accounts through the native bridge and checks both sides:

- A new transfer between on-budget accounts adds its linked transaction with the opposite amount and the same notes. The chosen category is dropped, and both balances change. Register rows name the other account and the direction. Transfer payees are not listed as ordinary payees.
- Edits from the receiving side carry the amount and notes to the sending side. Each side keeps its own date and cleared state, as in Actual.
- Choosing an off-budget account moves the linked transaction there and keeps the category. Choosing an ordinary payee removes the linked transaction; choosing an account again adds a new one and drops the category.
- A transfer to the transaction's own account is rejected, including by moving one side into the other account.
- A reconciled linked transaction blocks edits and deletions until its own confirmation is given; confirming this side alone is not enough. A confirmed edit updates the linked transaction, which stays locked.
- Deleting a transfer deletes both sides and restores all three balances.
- A transfer linked to a split child is view only and cannot be edited or deleted, but can still be cleared.

Disabling the linked-reconciled check, or the split-linked check, made this test fail. `./scripts/test-transactions.sh` checks transfer titles, categories, search, and the view-only state.

`./scripts/test-sync.sh` now edits the rule-created transfer offline from its receiving side; the upstream API then checks both amounts, the notes, and both balances. It passed. The script prints its free port as plain text, since `FORCE_COLOR` would otherwise add color codes that stop the server from starting.

The UI test `testDemoTransfer` transfers from Capital One Checking to Ally Savings through the payee list. It checks that the account cannot transfer to itself, the payee and category rows, and both register rows. It then deletes the transfer from Ally Savings and checks that both sides are gone. It passed with the demo navigation and reconciliation tests on a new iPhone 17 Pro / iOS 26.0 simulator, run with `-parallel-testing-enabled NO`. The first runs failed in the test itself: it typed a `.` decimal on a simulator using `,`, and then tapped the form's delete button instead of the dialog's. Screenshots of the payee list, editor, both registers, and the delete confirmation were inspected.

Strict bridge type checking, native engine/recovery tests, bank-sync regressions, automatic sync, and the 10,000-transaction regression also passed. Transfers on a physical device and against a live server were not verified.

## OpenID sign-in (2026-09-25)

`./scripts/test-openid.sh` starts a temporary server, creates the encrypted fixture with a server password, and enables OpenID through `/openid/enable`, as Actual's Settings does. The provider is `Tests/openid-provider.cjs`, a minimal local OpenID provider that approves at once as one user. It checks the client secret, redirect address, and PKCE verifier, and signs its ID tokens. The native harness runs through `AppModel` and the bridge:

- The server offers its active OpenID method first, then password. No OpenID owner exists yet.
- Before the first OpenID sign-in, a missing or wrong server password is rejected, as in Actual, and the provider's page is never opened. Cancelling on the provider's page reports nothing. A return address without a token, and an unknown session token, are rejected, and the previous token is kept.
- Following the redirects as a browser would, the server sends the session to `actualnative://localhost/openid-cb?token=…`. The app keeps the token, lists the budgets that now belong to the new owner, then downloads and syncs the encrypted budget.
- Later OpenID sign-ins need no server password.
- A fresh installation can still sign in with the server password while OpenID is active, since the server does not enforce OpenID.

Pointing the return address at another host made the test fail at its first OpenID step: the server accepts only its own host or `localhost`. Strict bridge type checking, the native engine, encrypted sync, automatic sync, bank-sync, and 10,000-transaction regressions also passed.

`./scripts/test-openid.sh --simulator SIMULATOR_ID` runs the UI test `testOpenIDSignIn` against a fresh server instead. The test enters the address and checks that OpenID stays disabled until the server password is entered. It confirms the system's sign-in prompt and waits for the server's budgets. It passed on a new iPhone 17 Pro / iOS 27.0 simulator. The server log shows the provider's redirect back to `/openid/callback`, then the session's validation and budget listing. The first run failed in the test itself: the simulator was set to Italian, so the prompt's button read "Continua". The test now taps the prompt's last button. Screenshots of the sign-in options, the prompt, and the connected state were inspected. They showed that the owner warning stayed after the first sign-in, and that OpenID stayed disabled once the password field was cleared. The form now records that the owner exists, and the test checks that OpenID is enabled after sign-in.

A live identity provider such as Pocket ID, passkeys, and sign-in on a physical device were not verified. If the server's callback fails, for example because Actual's user directory has no user for this account, the sign-in sheet shows the server's error text, as in Actual's web app. Close the sheet to return.

## Deleting local budgets (2026-09-25)

Touch and hold a budget in the list to delete it from this device, as with Actual's **Delete file locally**. The bridge calls upstream's `delete-budget` with only the local ID, so the server is never contacted. A server budget can be downloaded again, but changes not yet synced are lost; the confirmation says which case applies. Upstream's handler opens the budget's database before deleting it, which would replace an open budget, so the bridge closes any open budget first. It also forgets this app's last-opened budget and sync-warning settings for the deleted budget.

`./scripts/test-engine.sh` copies the demo into two listed local budgets and deletes the one opened at launch. It checks that an unknown ID is refused, that the budget's directory and its settings are removed, that the next launch opens nothing, and that the other budget and its settings are unchanged, and that it still opens.

The opt-in UI test `testDeleteLocalBudget` needs a disposable local budget named `Delete Budget Regression`. Install the fixture as for `testLargeBudgetTransactionsStayResponsive`, in `Library/Application Support/ActualNative/delete-regression/`, with a copy of a disposable budget's `db.sqlite`, such as the demo's, and `{"id":"delete-regression","budgetName":"Delete Budget Regression"}` as `metadata.json`. The test cancels once and then deletes. It checks that the budget leaves the list and does not return after relaunch. It passed on a new iPhone 17 Pro / iOS 27.0 simulator, and the app's data directory then held only `settings.json`. The first run failed in the test itself: on iOS 27 the confirmation is a popover anchored to the row, without a Cancel button, so the test now taps outside it. Screenshots of the menu, the confirmation, and the emptied list were inspected.

Strict bridge type checking, native engine/recovery tests, and the signed simulator build also passed. Deleting a downloaded server budget was checked in code, not end to end; its confirmation text was not seen on screen. Deleting a budget from the server remains in Actual web/desktop.

## Engine bundling in Xcode (2026-09-25)

A device build ran new Swift code against an older `engine.js` and failed with "Unknown operation: deleteBudget". Xcode had only copied whatever bundle `./scripts/build.sh` last made. The app target's first build phase now runs `scripts/xcode-build-engine.sh`, which rebuilds the engine on every build in about half a second.

With `engine.js` replaced by a stale file, both a full and an incremental simulator build regenerated it, and the app's copy matched the regenerated bundle. The log shows the script before the engine copy. With a bare `PATH`, as for Xcode opened from the Dock, the script found Node through nvm's default. With nvm and `ACTUAL_SOURCE` unavailable, the settings in `.xcode.env.local` were enough. A missing Node or Actual checkout stops the build with an `error:` line that names the setting to fix.

## Calculator amount entry (2026-09-25)

Transaction, budget, and reconcile amounts use a calculator keypad instead of the system keyboard. Upstream's mobile keypad (`CalculatorButtons`, behind the experimental `mobileCalculator` flag) set the layout: AC ( ) ÷ / 7 8 9 × / 4 5 6 − / 1 2 3 + / ⌫ 0 . =. Its keys show the locale's digits and decimal separator. `Money.parse` follows loot-core's `evalArithmetic`: + - * / with the usual precedence, parentheses, and signs. Like the keypad, it omits `^`. Arithmetic uses exact decimals rather than JavaScript floats. The result is rounded to the cent with `Math.round`'s rule, so halves round upward. A lone number keeps the earlier limit of two decimal places, and division by zero is invalid. As in Actual, **=** and leaving the field replace the entry with its result. Upstream's + / −, Reset, Dismiss, and Apply row is left out: the sheets already have Save and Cancel, and the transaction editor has Payment/Deposit.

`./scripts/test-amounts.sh` covers lone numbers, operators, precedence, parentheses, signs, rounding, invalid input, and US, German, French, Swiss, and Egyptian Arabic formats, with round trips of `Money.editable`. The UI tests enter amounts with the keypad: `120+30` for Food's budget, `0` for the reconcile balance, and `40+3,21` for a transfer. They check **=**, then the saved budget row and the linked transfer's amount. All three passed on a new iPhone 17 Pro / iOS 26.5 simulator set to Italian. The first run found no keypad: the input view had zero height, so it now has an explicit frame. Screenshots of each editor in light appearance, and of the transaction editor in dark appearance, were inspected. Entry with a hardware keyboard, and the keypad on a physical device or iPad, were not verified.

## Faster transaction entry and optimistic edits (2026-09-27)

A new transaction opens with its amount focused and the keypad up, as upstream's mobile `TransactionEdit` does (`autoFocus={isAdding}`). Choosing a date closes the compact calendar. Income amounts are green in the register and in the editor while **Deposit** is selected. Each register row has a checkmark to clear or unclear the transaction, or a lock to unlock it after a warning. Upstream makes this icon tappable only while reconciling; here it always is.

Adding, editing, deleting, clearing, and unlocking a transaction show immediately. Upstream's mobile editor also saves without waiting and navigates back (`onSave(...); navigate(-1)`). `AppModel` keeps the engine's last-loaded register and accounts, and shows them with pending `TransactionChange`s applied. Each change is applied against that base, so applying it where the engine has already saved it changes nothing. A reload that lands mid-save therefore neither drops nor double-counts it. A change stays pending until the reload after its save, and is removed at once if the engine rejects it; the error then shows in the register. Edits no longer set `isBusy`, so the register stays usable while one saves. New transactions pass their ID to the engine as `newId`, so the shown row and the saved one match. Rules may still change a new transaction's payee or category; the reload shows their result. A transfer's linked transaction is updated only for amount and notes, and a new transfer's linked side appears on reload.

`./scripts/test-transactions.sh` applies each change, twice, to a register with a reconciled transfer and checks order and balances. `./scripts/test-engine.sh` runs `Tests/OptimisticEdits.swift` on the demo. It checks that a cleared change shows before the save finishes, without blocking a second edit, and that a new transaction shows at once and keeps its ID. It also checks that a deletion shows at once, that an invalid date is undone and explained, and that the register and balances then match a fresh reload. The editor, reconciliation, and transfer UI tests passed on a new iPhone 17 Pro / iOS 27 simulator. They check autofocus, the calendar closing, clearing from a row, the lock after reconciling, and saving and deleting with the editor closing immediately. Screenshots of the register and editor were inspected. Save failures after the editor has closed lose the draft, as in upstream's mobile app.

## Category targets (2026-09-27)

Targets follow Actual's budget automations editor (`desktop-client/src/components/modals/BudgetAutomationsModal` and `components/budget/goals`) and its `budget/*` template handlers. `Engine/targets.ts` ports the client-side parts: reading `#template` notes, migrating legacy templates, and the editor's validation messages. It saves with `budget/set-category-automations` using the `ui` source, previews with `budget/dry-run-category-template`, and applies with `budget/apply-single-template`, `budget/apply-goal-template`, and `budget/overwrite-goal-template`. Template amounts are decimal currency units in Actual, and integer minor units across the bridge, converted with the budget currency's decimal places as upstream does. Unlike the web editor, opening a category with notes templates does not store them; only saving writes. As on the web, saving first stores the category's `#cleanup` lines, which Actual ignores once the editor manages it.

`./scripts/test-engine.sh` exercises targets on the demo budget:
- It previews a fixed amount exactly and flags a refill without a cap.
- It flags percentages over 100%, accepts a fractional percentage, and refuses to save invalid targets.
- It stores decimal amounts with the `ui` source, reads them back in minor units, and applies one category's target, so its budgeted amount and goal match.
- With a long-term goal added, it checks the goal and the balance comparison.
- It reads notes templates, with descriptions and a `#cleanup` line, without writing `goal_def`, and reports unreadable notes lines.
- Saving migrated targets keeps the notes. Overwriting the month budgets every category with targets, skipping unreadable lines as Actual does. Applying without overwrite leaves budgeted categories alone.

Applying budgets no more than is available, and a balance cap limits it to the cap less the carried-over balance. Both match Actual; the test frees this month's funds first.

The UI test `testDemoTargets` passed on a new iPhone 17 Pro simulator:
- It adds a fixed amount to Food, sees the live projection and summary, saves, and applies.
- It checks that the row shows the applied amount and its funding. As in Actual, an overspent category shows **Overspent** instead, which the demo's random spending can cause.

In the full UI suite on a new simulator, the demo navigation, reconciliation, and transfer tests also passed; the opt-in fixture tests were skipped.

Target amounts use the calculator keypad, like other amounts. A target's amount updates whenever the entry is a complete amount or calculation, so a partial entry such as `40+` keeps the previous amount until it is finished. The suite passed again with the keypad field.

Screenshots of the target form, the targets list, and the funded budget row were inspected. A `Menu` for choosing the kind of a new automation did not open under XCUITest in the sheet. The app now follows the web editor instead: **Add Automation** starts a fixed amount, and its **Type** picker changes the kind.

Not verified end to end: schedule, percentage, history, weekly-cap, and early-spending forms on screen (their saved formats are validated by the engine); targets synced to Actual web and shown there; tracking budgets; and VoiceOver.

## Reports (2026-09-27)

Reports follow Actual's `desktop-client/src/components/reports` at the pinned revision: `Overview.tsx` for the read-only, one-column mobile dashboard, `reportRanges.ts` and `dateRangePresets.ts` for ranges, the card and page components in `reports/`, and the calculations in `spreadsheets/`. `Engine/reports.ts` ports the net worth, cash flow, spending, summary, and calendar calculations, including net worth's alignment of transfer legs posted on different dates. It reads each widget's saved filters and time frame itself and returns integer minor units; upstream's fractional averages and daily budgets are rounded when returned, as Actual rounds them for display.

`./scripts/test-engine.sh` runs `Tests/EngineReports.swift` on a new demo budget, which has Actual's default dashboard. It checks every value against sums read directly from Actual's `v_transactions` view, with splits inline as Actual's queries see them:
- Dashboard: the default widgets top to bottom, then left to right; seeded widgets in order; Markdown content and alignment; a custom report whose report is missing; an experimental widget hidden until its feature flag is on.
- Net worth: the total at the end of every month in the default six months and in a one-year range, assets less debt, and the change. A year to date by week ends today. A widget filtered to one account shows only that account.
- Cash flow: on-budget income and expenses without transfers through today, the daily detail's totals, transfers and running balance, and a monthly detail over a year.
- Spending: this month to date against last month, the budgeted amount, and the three-month average, with the card's difference.
- Summary: sum, average per month, average per transaction, and percentage, with the default dashboard's year-to-date expense filters.
- Calendar: a live three-month range, each month's income and spending without transfers, and one day's transactions.
- Custom reports and removed widgets fail with a clear message.

The UI test `testDemoReports` passed on a new iPhone 17 Pro / iOS 27 simulator. It opens the demo's dashboard and the detail pages of a summary, net worth (switched to one year), cash flow, spending (switched to the budget comparison), and the calendar (showing one day's transactions), then scrolls to the text widget. Screenshots of each were inspected. The demo navigation test also passed with the new tab, as did the bank-sync and automatic-sync suites.

Not verified end to end: dashboards with several pages, stacked net worth, custom reports and other widgets on real budgets, tracking budgets' spending comparison, dark appearance, and VoiceOver.

## Budget actions, management, splits, and schedules (2026-09-29)

`./scripts/test-engine.sh` and `node Engine/typecheck.mjs` passed with four new engine suites against the demo budget, with upstream Actual 26.9.0:

- Budget actions: copy last month, zero, 3-month average, one category's copy and 6-month average, one category's 12-month average matching what Yearly Average budgets, To Budget to a category, category to category and to To Budget, over-balance and same-category rejections, movement notes, covering overspending from To Budget and from a category, covering an overbudgeted month, holding (added to an existing hold) and releasing, disabling the automatic hold, and rollover from this month on.
- Management: group and category creation, renaming with unique names, reordering, hiding, notes for a category, group, month, and account, deletion with the required receiving category, local accounts on and off budget with starting balances, renaming, closing with a transfer and category, reopening, deleting an account without transactions, and force closing.
- Splits: unbalanced splits rejected and not saved, creation, editing parts, moving the whole split to another account and date, removing parts, unknown parts rejected, unsplitting, splitting again, and deleting with its parts.
- Schedules: required dates and unique names, repeating and one-time schedules, upcoming dates, a range amount, posting today (at the range's midpoint) and the paid status, skipping, completing, restarting, a schedule without an account refusing to post, and deletion.

`./scripts/test-transactions.sh` passed after register search was extended to split parts' categories and notes.

The UI tests `testDemoBudgetActions`, `testDemoManagement`, `testDemoSplitTransaction`, and `testDemoSchedules` passed on an iPhone 17 Pro simulator, reusing one demo budget across runs, so the new tests use names unique to each run. Screenshots of the banners, month menu, budget summary, move form, category editor, split editor, reopened split, schedule editor, and schedules list were inspected. First runs failed in the tests themselves: a menu toggle is a button to XCUITest, fields with a placeholder prompt needed an explicit label, rows below the keypad had to be scrolled into view, and an iOS 27 confirmation repeats its button's label.

Not verified end to end: syncing these changes with Actual web on a server budget, bank-linked accounts when closing, schedules with date patterns set in Actual, tracking budgets' rollover, dark appearance, and VoiceOver.

## Upcoming, uncategorized, payees, rules, formatting, and split transfers (2026-09-29)

`./scripts/test-engine.sh`, `node Engine/typecheck.mjs`, and `./scripts/test-transactions.sh` passed, with new checks for upcoming scheduled transactions (the due date at a range's midpoint, removed once paid), payees (rename, merge moving transactions, deleting unused ones), rules (validation, creation, matches, applying, editing, schedule rules kept), formatting settings (saved, limited to Actual's choices, and applied to amounts and dates), split parts with their own payee and with a transfer that adds, updates, and removes its other side, and the category and uncategorized lists.

The schedules test failed intermittently while skipping a date. Actual looks up a schedule's rule with an AQL calculation, which reads the first column of the result, and rows crossed the native SQLite bridge as dictionaries, which do not keep column order. The bridge now returns rows as values in SQLite's column order; a host test checks it, and the engine suites then passed in several runs in a row.

`./scripts/test-sync.sh` passed with native offline edits synced through a disposable server and read back with Actual's API: a budget amount and rollover, a new group, category, and category note, a split with a transfer part (both balances exact), a renamed payee, a schedule, a rule, and the number format.

The UI tests `testDemoUpcomingAndCategoryTransactions` and `testDemoPayeesRulesAndFormatting` passed on an iPhone 17 Pro simulator; screenshots of the upcoming section and its menu, a category's transactions, payees, rules, a new rule, the formatting settings, and the budget in the 1.000,33 format were inspected. First runs failed in the tests: the category's Transactions link shared its label with the tab, and the iOS 27 scheduled menu has no Cancel button. A new rule's empty payee is valid in Actual (payee is nothing), so the test checks the new rule instead of an error.

Not verified end to end: rules with every operator on real budgets, merging payees used by schedules, and the date format on budgets using locales other than the device's.
## Compact budget screen and quick filters (2026-09-28)

The Budget screen follows Actual's mobile budget at the pinned revision (`desktop-client/src/components/mobile/budget`). Category rows fit on one line, with **Budgeted** and **Balance** columns as in `BudgetTable.tsx`. Group headers show Actual's `group-budget` and `group-leftover` sheet values, which `api/budget-month` returns with each group, as `ExpenseGroupListItem.tsx` does. Like Actual, these include the group's hidden categories. The month switcher, budget name, and summary card take about half their previous height.

The **Overspent** filter lists every expense category with a negative balance, as its red row shows. Actual's mobile overspending banner (`useOverspentCategories`) leaves out categories that roll over overspending, because it offers to cover them; this filter lists them too. **Underfunded** lists categories whose goal difference is negative, which the row shows in orange unless the category is also overspent.

`./scripts/test-engine.sh` checks, in the demo's envelope budget and again as a tracking budget, that every expense group's budgeted, spent, and balance totals equal the sums of its categories; the demo hides none. It also checks that the Overspent filter shows exactly the negative-balance categories, in budget order, and keeps each group's full totals. The targets test checks that a long-term goal is listed as Underfunded until the balance reaches it. Strict bridge type checking passed.

`testDemoBudgetNavigationAndTransactionEditor` and `testDemoTargets` passed on a new iPhone 17 Pro / iOS 26.0 simulator. The first now selects **Overspent** and checks that every listed row is overspent. Rows keep an accessibility label with the category's name, budgeted amount, balance, and funding status, which the targets test reads. Screenshots were inspected in light and dark appearance, with the Overspent filter selected, with a funded target, and at an accessibility text size. At accessibility sizes, the summary, group headers, and rows stack their amounts under the name, and the filters scroll sideways. `docs/screenshots/02-budget.png` and `06-budget-dark.png` show the new layout.

Not verified end to end: iPad width, VoiceOver, and budgets with hidden categories in a visible group.

## Merging the compact budget screen (2026-09-29)

The compact budget screen and quick filters from `origin/main` were merged with this batch. Group headers keep Actual's totals and now open the group's menu, as Actual's mobile budget does; hidden categories respect the quick filters and the Show Hidden Categories choice; income is listed below expenses when no filter is chosen. The engine, transaction, and typecheck suites passed, and on a newly erased iPhone 17 Pro / iOS 27.0 simulator every demo UI test passed, with the navigation test run first on its own because it starts from the welcome screen. Test fixes: category rows are told apart from group headers by the headers' `group-header` identifier, controls below the fold are scrolled to, and the scheduled menu's popover is closed through its dismiss region.

## Tags, schedule days and links, file import, widget, background refresh, and Shortcuts (2026-09-29)

`./scripts/test-engine.sh`, `node Engine/typecheck.mjs`, and `./scripts/test-transactions.sh` passed with new checks: tags discovered from notes (with `##` escapes), created, recolored, renamed in every note, hidden, and deleted; monthly schedules on the last Friday and the 15th, with invalid patterns refused and patterns dropped for other frequencies; a matching transaction linked to and unlinked from a schedule; the upcoming window saved; and imports of OFX (a second import matches instead of duplicating; payees title-cased as Actual imports them), CSV with guessed columns and with separate debit and credit columns and day-first dates, and QIF, with other files refused.

On a new iPhone 17 Pro / iOS 27.0 simulator, every demo UI test passed, including the new `testDemoTagsAndSpecificDays`, with the navigation test run first on its own. After the tests, the app's App Group container held the widget snapshot, with To Budget and the four categories most in need in the budget's number format. The widget extension builds and is embedded in the app.

Not verified end to end: the widget on a home screen, background refresh as scheduled by iOS, Shortcuts and Siri running the intents, importing through the Files picker, and signing the App Group on a device.

## Design pass: register, accounts, and dark accent (2026-09-29)

Changes from a design review, checked against Actual's `DESIGN.md` and its mobile components at the pinned revision. Registers, category transactions, schedule links, and the import preview show spending in the text color and income in green, as `TransactionListItem.tsx` does; upcoming amounts are secondary. The leading direction badge is gone; transfers and splits keep a small glyph beside the category. The cleared toggle is a body-size glyph, green when cleared, as Actual marks it. Account rows drop the icon tile and the "Current balance" filler, and section headers show totals, with **All accounts** for open accounts, matching `AccountsPage.tsx`. `ActualTheme.purple` and the asset accent use Actual's dark-theme `purple400` (#9446ED) in dark appearance.

The app built for an iPhone 17 Pro / iOS 26.5 simulator, and `testDemoBudgetNavigationAndTransactionEditor` (run first on a fresh install) and `testDemoReconciliation` passed. Screenshots of Accounts and Transactions in light, and Budget in dark, were inspected; the account totals add up to the Net Worth report's total. `docs/screenshots/03-accounts.png` and `04-transactions.png` show the new layout.

## Themes (2026-09-30)

Upstream was checked first at the pinned revision (`desktop-client/src/style/theme.tsx`, `customThemes.ts`, and `components/settings/Themes.tsx`). Actual keeps its theme as a global preference of the device, not of the budget, so the app does the same. Actual's installable custom themes are CSS variables for its web interface; they cannot restyle native controls, so the app has its own small set of colors instead: accent, page, rows and cards, the summary card's two colors, and positive, warning, and negative amounts, each for light and dark appearance.

`./scripts/test-themes.sh` passed: colors read and write as `#RRGGBB`; in both appearances every preset that sets its own page and rows keeps iOS’s text at 7:1 or better on them, and its accent and amount colors at 4.5:1 or better on rows, and black or white text at 4.5:1 or better on the accent and on both ends of the summary card; a new theme copies the one in use with every color filled in; edits, unique names, saving, and deleting behave, and deleting the theme in use returns to Actual's.

On a new iPhone 17 Pro / iOS 26.5 simulator, the new `testDemoThemes` passed: it chooses Sterling and Payday, makes a theme, renames it, and deletes it. Every other demo UI test passed except `testDemoManagement`; `testDemoBudgetNavigationAndTransactionEditor` was run first on a fresh install. `testDemoManagement` fails the same way on the commit before this change: on this simulator the group sheet opens empty. Screenshots of Budget, a category's budget editor with the keypad, Accounts, Transactions, Reports, Settings, the theme list, and the theme editor were inspected for Actual, Sterling, and Payday in light and dark appearance, with Schedules, the welcome screen, the new-transaction editor, and its date picker in dark for the two new themes. Actual's theme looks as it did before. The review found white labels on prominent buttons, unreadable on Sterling's silver accent in dark appearance; those labels now use the black-or-white text chosen for the accent. After leaving the app with Sterling chosen, the App Group's widget snapshot held Sterling's accent and overspending colors.

`docs/screenshots/07-theme-sterling.png` to `11-theme-editor.png` show Sterling and Payday in both appearances, and the editor.

Not verified end to end: the widget drawn with a theme on a home screen, the system color picker sheet itself, colors chosen outside sRGB (they are stored as sRGB), themes on iPad, VoiceOver, and increased-contrast settings with the two new presets. The simulator needed a restart before a changed appearance took effect.

## Editing report widgets (2026-09-30)

Widget editing follows Actual's report pages and card menus at the pinned revision (`reports/reports/*.tsx`, `ReportCard.tsx`, `MarkdownCard.tsx`, `filters/FiltersMenu.tsx`, `dateRangePresets.ts`), which save a widget's meta with loot-core's `dashboard-update-widget`. `Engine/report-editing.ts` returns a widget's settings with Actual's defaults and saves only the settings that changed, merged into the widget as it is then.

`./scripts/test-engine.sh` and `node Engine/typecheck.mjs` passed. `Tests/EngineReportEditing.swift` edits the demo budget's default dashboard and reads each widget's stored meta directly, then its report:
- Net worth: opens with Actual's defaults; saves a name, a one-year range, weekly interval, stacked graph, and an account filter, and the report then shows them. A cleared name becomes `Net Worth`. The last four months save as a live range and reopen as one.
- Cash flow: saves fixed months and the balance line, and nothing else.
- Spending: the default widget keeps following the current month when only its comparison changes; a chosen month pins it, and **Current month** unpins it.
- Summary: a percentage with divisor filters and an all-time divisor keeps the default dashboard's font size in its content, its filters, and its range; **All time** starts at the first month with transactions.
- Calendar: a range of days, a filter on a month, a named condition, and a setting this app does not know all survive a save that changes only the filters.
- Text: Markdown and position.
- Refused, with nothing saved: another kind of widget's setting, an unknown interval, a fixed range that ends before it starts, an invalid average or month, a filter Actual cannot run (named by its position), and widgets edited in Actual.

`./scripts/test-sync.sh` passed with a widget's name and interval saved offline: after syncing, Actual's own API reads them from the server's copy.

`./scripts/test-auto-sync.sh` and `./scripts/test-openid.sh` passed. Their compile lists had fallen behind the files `AppModel` needs, so neither built; they now list the same models as `test-bank-sync.sh`.

The UI test `testDemoReportEditing` passed on a new iPhone 17 Pro / iOS 27 simulator, followed by `testDemoReports` on the same budget. It opens a spending widget's editor and cancels; renames a summary, tries fixed months, sets one year, switches to a percentage and back, and adds a transfer filter; saves a range from the report's page with **Save to Widget** and sees it in the editor; and edits the text widget. Screenshots of the editor, the filter editor, the page with **Save to Widget**, and the edited dashboard were inspected.

Not verified end to end: edited widgets as shown in Actual web (their stored meta and sync are checked instead), a percentage summary's divisor filters and the spending month pickers on screen beyond opening them, editing on a dashboard with several pages, dark appearance, and VoiceOver.

## Uncategorized badge in registers (2026-09-30)

`./scripts/test-transactions.sh` passed with a new check of which register rows ask for a category: a transaction without one and a split with a part without one, but not transfers, reconciliation adjustments (recognized by Actual's note, **Reconciliation balance adjustment**), or transactions in off-budget accounts.

The UI test `testDemoUncategorizedBadge` passed on a new iPhone 17 Pro / iOS 27 simulator. It adds a transaction without a category, then reconciles the account with an adjustment. In the screenshot, the new transaction has the badge and the adjustment beside it does not.

Not verified end to end: the badge on a split with uncategorized parts on screen (the count is checked instead), adjustments created by Actual in another language, whose note differs, custom themes, dark appearance, and VoiceOver.

## Split Evenly and Use Remaining (2026-09-30)

Checked against upstream Actual 26.9.0 (the pinned revision): the mobile editor's **Use remaining** and the desktop register's **Distribute**, which gives leftover cents to the first parts.

`./scripts/test-transactions.sh` passed with new checks of the arithmetic: an even share with extra cents first (10.00 in three parts is 3.34, 3.33, 3.33), no parts, and what one part needs given the others, including when the others exceed the total.

The UI test `testDemoSplitTransaction` passed on a new iPhone 17 Pro / iOS 26.5 simulator. It now fills the second part with **Use Remaining**, checks that the buttons disappear once the split balances, then uses **Split Evenly** to set both parts to 15.00. The split-editor screenshot was inspected. The first run failed in the test itself: the form unloads off-screen rows, so it now finds the button by its amount rather than by its position.

Not verified end to end: custom themes, dark appearance, and VoiceOver.
