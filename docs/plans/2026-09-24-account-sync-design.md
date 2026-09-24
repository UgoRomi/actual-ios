# Manual bank account sync

Approved on 2026-09-24. Pull to refresh Accounts to fetch transactions for all linked, open accounts. Pull to refresh an individual account register to fetch only that account. Unlinked and closed accounts keep local refresh behavior. Bank setup and reconnecting remain in Actual web/desktop.

Use Actual 26.9.0 at the revision in `Engine/upstream.json`. Its `accounts-get` handler exposes bank linkage and status; the public accounts API omits some of this metadata. Call `simplefin-batch-sync` once for selected SimpleFIN accounts and `accounts-bank-sync` for each other selected account, matching the upstream UI. Never pass an empty ID list: upstream treats it as all accounts. Keep imports, matching, rules, account preferences, and balance calculations inside Actual's engine.

Bank refresh is explicit and separate from Settings → Sync now, which exchanges budget changes with the server. Imported transactions are saved locally and included in the next budget sync. Require a connected server and token before requesting bank data. Existing compatibility/recovery warnings also block bank imports.

Show linked-account status, progress, last successful bank refresh, and actionable account-specific failures. A failed account must not hide successful imports from other accounts. Refresh the snapshot after both successful and failed attempts; preserve bank errors until another attempt or a budget switch. Disable overlapping commands using the existing busy state. Return structured results instead of treating a partial import as an all-or-nothing failure.

## Implementation plan

1. Add bank metadata to snapshots and a guarded bank-sync command using upstream handlers.
2. Add typed native results/state and wire pull-to-refresh on Accounts and account registers.
3. Exercise the native engine against a disposable local bank-response fixture: selection, SimpleFIN batching, exact imports, repeat matching, failures, persisted status, and recovery guards. Build the iOS app and run appropriate existing regressions.
4. Update the README, existing design, and validation notes with delivered behavior and test limits.

The brainstorming skill's follow-on `writing-plans` skill is unavailable in this installation; this concise implementation plan serves that step.
