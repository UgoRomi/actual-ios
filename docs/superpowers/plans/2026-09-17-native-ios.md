# Native iOS Everyday Budgeting Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** A separate native iOS everyday budgeting app backed by Actual's engine.

**Architecture:** SwiftUI presents typed engine snapshots. Actual's pinned JavaScript runs on a serial JavaScriptCore runtime with Swift host adapters. Native storage persists all changes offline; the existing engine handles server sync.

**Tech Stack:** SwiftUI, JavaScriptCore, SQLite3, Foundation, Security, CryptoKit/CommonCrypto, TypeScript, esbuild.

**Spec:** `docs/plans/2026-09-17-native-ios-design.md`

## Global Constraints

- iOS 26 and later; all visible UI is SwiftUI.
- Actual purple (#8719e0), navy neutrals, and semantic money colors.
- Keep money as integer minor units; all budget writes go through Actual.
- No personal server or budget is used for tests.
- Project remains separate from the upstream Actual checkout.
- New TypeScript uses no `any` types or `as` assertions.
- Do not dispatch subagents from implementation workers.

### Task 1: Native Screens and State

**Files:** Create `Native/Models.swift`, `Native/AppModel.swift`, `Native/ActualNativeApp.swift`, `Native/Views/*.swift`, `Native/Theme.swift`.

**Interfaces:** Consume `EngineClient.call(_ method: String, arguments: [String: JSONValue]) async throws -> Data`; `EngineClient()` is a throwing initializer. EngineClient is supplied by the engine task and is Sendable. Define JSONValue in Models.swift with null, bool(Bool), number(Int), string(String), array([JSONValue]), object([String: JSONValue]); Codable and Sendable. Engine methods return JSON:

```json
{"method":"bootstrap","result":{"budgets":[{"id":"local-id","name":"Household","cloudFileId":null}],"activeBudgetId":null}}
{"method":"snapshot","args":{"month":"2026-09"},"result":{"budgetName":"Household","month":"2026-09","currencyCode":"EUR","toBudget":50000,"totalBudgeted":200000,"totalSpent":-75000,"accounts":[{"id":"a","name":"Checking","balance":250000,"offbudget":false,"closed":false}],"groups":[{"id":"g","name":"Essentials","categories":[{"id":"c","name":"Groceries","budgeted":40000,"spent":-10000,"balance":30000,"isIncome":false}]}],"transactions":[{"id":"t","accountId":"a","date":"2026-09-17","payeeId":"p","payeeName":"Market","categoryId":"c","categoryName":"Groceries","amount":-10000,"notes":"","cleared":true,"isParent":false,"isChild":false,"isTransfer":false}],"payees":[{"id":"p","name":"Market"}]}}
```

Commands `demo`, `open` {id}, `connect` {url,password}, `download` {syncId,password}, `sync`, `budget` {month,categoryId,amount}, `saveTransaction` {id? ,accountId,date,payeeId?,payeeName?,categoryId?,amount,notes,cleared}, `deleteTransaction` {id}, `close` return an object (connect returns `{budgets:[...]}`). Every command followed by snapshot refresh; bootstrap/open restore without network dependency. The runtime rejects unsupported transfers/splits. UI should offer an explicit budget ID download if server listing is unavailable. Errors are user-visible, retryable, and never overwrite drafts. Do not silently show demo figures if live loading fails.

Bank refresh extension (2026-09-24): account snapshots also include `bankSyncEnabled`, `bankSyncStatus`, and `lastBankSync` (upstream timestamp string in milliseconds, or null). `syncAccounts` {accountId?} returns `{accounts:[{accountId,added,updated,error}]}`; `error` is null on success. It refreshes existing bank connections only, with SimpleFIN batching and explicit nonempty account selections. Refresh the snapshot even on failure, and distinguish local bank imports from server budget sync. See `docs/plans/2026-09-24-account-sync-design.md`.

Automatic budget sync extension (2026-09-24): snapshots include `cloudFileId` (null for local budgets). Native opening/foreground waits for sync; successful writes and bank imports schedule asynchronous sync. Local save failures and sync failures have separate UI state. The bridge allows tracked sync to wait on network concurrently with ordinary commands, uses Actual's mutation queue for consistent snapshots, and fences budget/server lifecycle changes until sync settles. See `docs/plans/2026-09-24-automatic-budget-sync-design.md`.

- [x] Build the native app entry, onboarding, tabs, lists, month controls, editing sheets and typed Codable models against these contracts.
- [x] Implement localized integer amount parsing with `NumberFormatter` + decimal math. Use `Text(value, format:)` or formatter with monospaced digits; include sign and labels independently of color.
- [x] Handle loading, empty and error states; prevent overlapping mutations, confirm deletions; disable split/transfer edits clearly.
- [x] Provide a real demo action that calls the engine, not hardcoded UI fixtures.
- [x] Verify with `xcrun swiftc -parse Native/Models.swift Native/AppModel.swift Native/Views/*.swift`; the integration task runs the full simulator build.
- [x] Commit only this task's files and write its report.

### Task 2: Actual Engine and Native Host

**Files:** Create `Engine/build.mjs`, `Engine/entry.ts`, `Engine/adapters/*.ts`, `Native/Core/EngineClient.swift`, `Native/Core/SQLiteHost.swift`, `Native/Core/NativeHost.swift`, `Tests/EngineSmoke.swift`.

**Interfaces:** Implement the EngineClient interface above. JavaScript invokes `_native(operation, argumentsJSON)` and receives `{value: ...}` or `{error: ...}`. Native async HTTP settles `__nativeResolve(id, responseJSON)`. Swift calls `ActualBridge.request(id, method, argumentsJSON)` and JavaScript settles `_reply(id, responseJSON)`. JSON encodings preserve integers exactly within JavaScript safe integer bounds. Runtime serializes ordinary public requests; tracked sync may wait on network concurrently, with lifecycle barriers and upstream mutation serialization.

- [x] Bundle the pinned core with esbuild, compiling Peggy grammars and injecting native platform adapters. Copy default SQLite template and all migrations into app resources.
- [x] Implement actual parameterized SQLite, savepoint rollback, required Unicode functions, bounded sandbox file access, compatible AES-GCM/PBKDF2, timers, and URLSession HTTP.
- [x] Invoke core handlers for every command; map native snapshots without recalculating budget values in Swift.
- [x] Persist last-opened budget and server settings; put authentication material in Keychain; reopening offline must bypass initial remote validation.
- [x] Write and execute a smoke test whose assertions cover:
```swift
precondition(after.amount == -1234)
precondition(afterRestart.amount == -2345)
precondition(afterRestart.balance == expectedBalance)
```
- [x] Extend the executable smoke harness to check SQLite rollback and encryption vectors. Run against a temporary data directory only.
- [x] Record the pinned upstream commit and adapter limitations.

### Task 3: Simulator Build and Sync Verification

**Files:** Create `ActualNative.xcodeproj/project.pbxproj`, `scripts/build.sh`, `scripts/test-engine.sh`, `README.md`, `docs/validation.md`.

**Interfaces:** Include every file in Native, link SQLite3 and system frameworks, copy Native/Resources as folder resource with nested migrations.

- [x] Generate a portable Xcode app project with iOS deployment target 26.0, a provisional independent bundle ID, and native app asset catalog.
- [x] Run the engine smoke harness; then boot a simulator and build with `xcodebuild -project ActualNative.xcodeproj -scheme ActualNative -sdk iphonesimulator -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build`.
- [x] Create a temporary sync server and budget, make changes in the native engine, verify them through upstream API, and test an offline edit surviving restart and reconnect.
- [x] Inspect screenshots of onboarding, budget, accounts, transactions and entry sheet; fix clipping, contrast and navigation problems.
- [x] Document exact build/run commands, security/storage behavior, compatibility range and tested limitations. Place the separate project next to Actual only after checks.
- [x] Run task review and final review; resolve material findings before delivery.

## Completion

Tasks 1–3 implemented and reviewed. Strict bridge typing, native engine/recovery tests, encrypted direct sync (including process restarts, wrong passwords, failed-download recovery, and rule-created transfers), and signed simulator UI smoke passed. Six screenshots are in `docs/screenshots`. The later automatic-sync extension replaces the original explicit-only UI policy. Untracked upstream load-time uploads remain disabled; the native coordinator awaits due snapshot uploads within each tracked sync. See `docs/validation.md` for verification limits.
