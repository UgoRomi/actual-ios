# Account reconciliation

Follow Actual's mobile web reconciliation at the revision in `Engine/upstream.json`: `desktop-client/src/accounts/reconciliation.ts`, `modals/AccountReconcileModal.tsx`, `mobile/accounts/ReconcilingBanner.tsx`, and `mobile/accounts/AccountTransactions.tsx`.

An account register offers **Reconcile**. The sheet asks for the bank's current balance, prefilled with the cleared balance. Linked accounts offer the last balance reported by the bank. The sheet shows when the account was last reconciled. As in Actual, the target balance is not saved; it ends when reconciliation finishes or the budget changes.

While reconciling, the register shows the cleared balance, the bank balance, and the difference. Each transaction has a cleared toggle, including transfers and split transactions. Reconciled transactions show a lock; unlocking one asks for confirmation. **Create reconciliation transaction** adds a cleared adjustment for the difference, dated today, with rules applied. When the balances match, **Lock transactions** marks all cleared, unreconciled transactions in the account as reconciled. **Exit reconciliation** leaves them unlocked. Both record the reconciliation time, as Actual does.

Ordinary reconciled transactions become editable after the same warning as Actual's mobile editor. Deleting one also warns. Their cleared state stays locked in the editor. Moving one to another account unlocks it, as in Actual's desktop editor. Transfers and splits stay view only; transfers later became editable (`2026-09-25-transfers-design.md`).

The engine ports upstream's client helpers using its shared `updateTransaction`, so split children follow their parent. Only changed fields are sent through `transactions-batch-update`. The engine computes the adjustment from the current cleared balance. Locking refuses if the cleared balance changed after it was shown. Editing a transaction that was reconciled after the editor opened requires a new confirmation. Existing compatibility warnings block these writes. Each write triggers automatic budget sync.

## Implementation plan

1. Add cleared balance, bank balance, and last reconciliation to the accounts overview. Add engine commands for cleared toggles, unlocking, adjustments, and finishing, and allow confirmed edits of reconciled transactions.
2. Add native reconciliation state, the reconcile sheet, banner, row toggles, and editor warnings.
3. Extend the engine test with clearing, splits, transfers, adjustments, locking, unlocking, editing and deleting reconciled transactions. Build the app and run the demo UI test with a reconciliation.
4. Update the README and validation notes.

## Delivered behavior

As designed. The accounts overview includes each account's cleared balance, the bank's last balance, and the last reconciliation time. Cleared and lock changes reload only balances and the register. Like Actual, the bank's balance is recorded only on refreshes after an account's first, and then only for providers that report it on every refresh, such as SimpleFIN. The engine, bank-sync, recovery, sync, automatic-sync, and transaction regressions pass, as do the signed simulator build and demo UI tests. See `../validation.md`.
