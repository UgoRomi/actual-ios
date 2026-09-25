# Transfers between accounts

Follow Actual's mobile web editor at the revision in `Engine/upstream.json`: `desktop-client/src/components/mobile/transactions/TransactionEdit.tsx`, `autocomplete/PayeeAutocomplete.tsx`, `mobile/utils.ts`, `mobile/transactions/TransactionListItem.tsx`, `modals/ConfirmTransactionEditModal.tsx`, and loot-core's `server/transactions/transfer.ts`.

As in Actual, a transfer is a transaction whose payee is another account. The payee list offers open accounts under **Transfer to/from**, except the transaction's own account. It lists them before payees, because the accounts list is short and payees can number in the hundreds. Payment and Deposit set the direction. The register and editor show "Transfer to Savings" or "Transfer from Checking". A transfer between two on-budget accounts shows **Transfer** as its category and is saved without one, as in Actual; an off-budget account shows **Off budget**. A transfer from an on-budget account to an off-budget account keeps its category.

Existing transfers become editable. Actual's `transactions-batch-update` creates, moves, updates, and deletes the linked transaction in the other account. As upstream does, the amount, notes, and accounts carry over to the linked transaction; its date and cleared state stay independent. Choosing an ordinary payee removes the linked transaction, and deleting a transfer deletes both. A transfer whose linked transaction is part of a split stays view only, like splits: editing it from one side could unbalance the split or move part of it to another account.

Editing or deleting a transfer whose linked transaction is reconciled asks for confirmation, as in Actual. The engine checks both sides against the current data, so a confirmation cannot cover a side reconciled after the editor opened. It rejects transfers to the transaction's own account. Existing compatibility warnings block these writes. Each write triggers automatic budget sync.

## Implementation plan

1. Register rows report the other account, the linked transaction, and whether it is reconciled or part of a split. `saveTransaction` accepts a transfer account, and `saveTransaction`/`deleteTransaction` accept transfers with a separate confirmation for a reconciled linked transaction.
2. Add transfer accounts to the payee picker, transfer titles and categories in the register and editor, and the linked-transaction warnings.
3. Test creation, edits from either side, retargeting, conversion to and from a transfer, deletion, rejected same-account and split-linked transfers, and reconciled linked transactions. Extend the encrypted sync test so the upstream API verifies an offline transfer edit. Run the register regression and a demo UI test that creates a transfer.
4. Update the README and validation notes.

## Delivered behavior

As designed. Register rows report the other account, the linked transaction, and whether it is reconciled or part of a split. The engine resolves the other account's payee, checks both sides before any write, and leaves linking, moving, and deleting to Actual's `transactions-batch-update`. The engine, register, encrypted sync, bank-sync, automatic-sync, and demo UI tests pass. See `../validation.md`.
