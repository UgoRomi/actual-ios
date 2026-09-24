# Automatic budget sync

The user requested awaited budget sync when opening the app and asynchronous budget sync after edits, extending the manual bank-sync design. Opening includes cold launch, returning from the background, and choosing an existing server-backed budget. Keep the opening state visible and prevent edits until the sync attempt and snapshot reload finish. If the server is unavailable, preserve offline access and show a retryable sync error. Local/demo budgets do not attempt server sync. A later refinement skips the foreground sync within five minutes of a successful one, unless a sync has failed since. It also offers **Continue offline**, which releases the saved budget while the tracked sync continues in the background, as it does after an edit.

Persist edits first, then start a tracked sync task without holding the UI busy. New edits during an active sync request another pass, coalescing rapid changes. Include transaction creation/edit/deletion, category allocations, and bank imports/status changes. Keep Settings → Sync now as an explicit retry. Do not add periodic polling or an iOS background-task service; pending local changes survive suspension and retry on the next opening or edit.

Use one native coordinator instead of enabling unmanaged upstream timers: it can expose completion/failure and protect budget switching. A fully serialized network command would be simpler but would delay later local saves behind a slow server. Let the tracked sync request release the bridge command queue during network waits, while keeping JavaScript/SQLite on the existing serial runtime and using Actual's mutation serialization for writes and consistent snapshots. File changes, server reconnection, and closure must wait for the active sync to settle. Clear upstream sync timers when the tracked operation finishes.

Separate sync errors from local save errors. A failed upload must never make a completed edit appear unsaved. Guard delivery of each budget part (overview, month, register) against a changed budget/month or a newer request for that part. Preserve engine compatibility/recovery blocks and encryption behavior.

## Implementation plan

1. Add tracked concurrent budget-sync dispatch, lifecycle barriers, and cloud-budget metadata to the bridge.
2. Add native sync coordination, launch/resume gating, post-edit scheduling, and retry/status UI.
3. Test launch ordering, local edits while server responses are delayed, coalescing, offline durability/retry, and budget switching using disposable data and the real sync server. Run affected native, bank-sync, and simulator checks.
4. Update existing documentation to describe automatic budget sync and its offline/suspension limits.

The follow-on `writing-plans` skill remains unavailable; this plan covers the implementation steps.

## Delivered

Implemented the tracked bridge dispatch, native coordinator, opening/foreground gate, edit and bank-import scheduling, separate retryable errors, and budget-switch barriers. Incoming encrypted CRDT metadata now accepts raw buffers as well as file-download base64 strings. The delayed/offline encrypted-server harness verifies completion ordering, durable concurrent edits, coalescing, foreground exchange, switching, and local-only budgets. Engine, bank-import, encrypted-sync, and signed simulator UI regressions pass; see [validation](../validation.md) for scope and remaining device checks.
