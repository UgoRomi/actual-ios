# Native iOS Everyday Budgeting

Build a separate SwiftUI application for iOS 26 and later. The user selected everyday budgeting: budgets, accounts, and transactions, with offline use and direct sync to an Actual server. Keep all visible UI native, use system Liquid Glass navigation and controls, and retain Actual purple (#8719e0), navy neutrals, and semantic money colors. Support dark mode, Dynamic Type, VoiceOver, reduced transparency and motion through system controls. Financial content uses opaque surfaces and monospaced digits.

## Engine

Bridge a pinned Actual engine through JavaScriptCore. Use its existing handlers, calculations, rules, migrations and sync rather than reproducing money logic in Swift. Swift supplies sandboxed files, SQLite, cryptography, timers and HTTP. A dedicated serial runtime queue keeps JS and SQLite off the main thread. A typed Swift facade owns commands and result decoding. Keep money as integer minor units.

All budget mutations go through Actual handlers. The engine is the sole database writer. Persist before acknowledging a mutation. Surface storage, authentication, version, and sync failures; a local save and a successful sync are distinct states. Store server credentials/tokens in Keychain. An unavailable server must not stop local reopening. Never use a live personal budget for validation; use disposable local data and a temporary server.

JavaScriptCore is the preferred bridge, subject to the feasibility test. A bundled WebKit engine is a fallback if core runtime requirements cannot be supported reliably. A complete Swift port is deferred due to ongoing compatibility costs. Pin the upstream commit and retain license notices.

## Experience

Budget is the default tab, with month navigation, available-to-budget summary, grouped categories and editable allocations. Accounts lists balances and opens transaction registers. Transactions supports searching, adding, editing, categorizing and deleting, with explicit confirmation for deletion. Transfers and splits must preserve their structure; unsupported editing paths must be clearly disabled. Transaction entry is a native sheet. Settings includes server connection, budget selection and visible sync state. Start with a demo or connect to the user's server.

Use the existing budget's formatting preferences where supported; do not silently assign a different currency. Store values in integer cents and parse text with locale awareness. Scope excludes reports, bank-link setup, rule editors, widgets and Shortcuts for the first deliverable.

## Validation

First prove: create a disposable Actual budget, add/edit a transaction offline, stop and recreate the runtime, reopen and verify exact balances, then round-trip through a temporary Actual sync server. Test rollback, parameter binding, Unicode SQL functions, missing files, encryption compatibility and invalid server responses. Build an iOS simulator app and visually inspect the three tabs and editing sheet. Document any unverified feature without presenting it as complete.
