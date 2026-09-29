# Actual Native

An unofficial SwiftUI iOS client for Actual Budget. A separate app with native Liquid Glass navigation, Actual purple and navy, and the real Actual engine running locally through JavaScriptCore.

This is a development build, with no App Store submission or distribution signing configured.

## What works

- Open a real demo or download a budget from your Actual server.
- Delete a budget from this device: touch and hold it in the budget list. As with Actual's **Delete file locally**, a server budget stays on your server and can be downloaded again, but changes not yet synced are lost. A budget that is not on a server is deleted permanently. Deleting a budget from the server remains in Actual web/desktop.
- Browse monthly envelope or tracking budgets, adjust category allocations, and see account balances, including future-dated transactions as in Actual. Tracking budgets show saved or projected savings instead of an amount to budget.
- Move money as Actual's budget menus do. The **Month actions** menu copies last month's budget or sets every category to zero or its 3-month, 6-month, or yearly average, after confirmation. A category's budget editor copies its own last-month amount or average, and turns overspending rollover on or off from that month onward. In envelope budgets it also transfers a positive balance to another category or back to To Budget, and covers overspending from another category or To Budget. Tap the summary card to see how To Budget adds up and to move it to a category, hold it for next month, cover an overbudgeted month from a category, or release a hold. Banners list overspent categories to cover and warn when you have budgeted more than is available. As in Actual, each move is recorded in the month's notes.
- Each budget row shows a category's budgeted amount and balance on one line, with overspent balances in red. As in Actual's mobile budget, each group's header shows its total budgeted and balance. Like Actual, these totals include the group's hidden categories. Quick filters show only **Overspent** categories, those with a negative balance, or **Underfunded** ones, whose targets ask for more than they have. Underfunded appears once applied targets set goals. Each filter shows how many categories it matches.
- Set category targets, which Actual calls budget automations or goal templates. In a category's budget editor, choose **Add Targets**. Every kind Actual's editor offers is available: fixed amount, cover schedule, save by date, % of income, from history, refill to cap, whatever is left, balance cap, and long-term goal. As you edit, the app shows what the targets would budget this month and flags anything to fix before saving, using Actual's own checks. Targets are saved in Actual's format, so Actual web/desktop shows and applies them too. Targets written as `#template` lines in a category's notes appear in the editor; saving moves them to the editor, as in Actual, and leaves the notes unchanged. Notes lines Actual cannot read must be fixed in Actual first.
- Apply targets as Actual does: **Apply Target** in a category's budget editor, or the target menu on the Budget screen to fill categories with nothing budgeted yet or to overwrite every category with targets. Like Actual, applying budgets no more than is available. After targets are applied, each row colors its balance as Actual does: orange if the category is underfunded, green once funded. The category's budget editor shows whether it is underfunded, fully funded, or overfunded, and by how much. A long-term goal compares the balance with the goal. Actual web keeps targets behind its experimental **Goal templates** feature; this app offers them for every budget.
- See your reports as Actual's mobile web app shows them: the budget's report dashboards, read-only, in one column. Net worth, cash flow, spending analysis, summary, calendar, and text widgets are drawn natively with their saved filters and ranges; these are all the kinds in Actual's default dashboard. Open a report to see its detail and try another range, or for spending analysis, another comparison; these choices are not saved. Choosing a day in a calendar lists its transactions. Custom reports, age of money, crossover point, and experimental widgets whose feature flag is on show a note to open them in Actual web or desktop.
- Pull to refresh Accounts to fetch bank transactions for all linked, open accounts, or refresh one account from its transaction register. Shows bank refresh status and account-specific errors; existing rules and import preferences apply.
- Registers open with the newest transactions and add older ones as you scroll, as Actual pages them, so budgets with years of history open quickly. Search covers every transaction.
- Search transactions; add, edit, categorize, clear, and delete ordinary transactions. Tap a transaction's checkmark to clear or unclear it; income amounts are green. A new transaction opens with its amount ready for entry, and choosing a date closes the calendar. Payees and categories are chosen from searchable lists, and typing a new name adds a payee. As in Actual's mobile app, rules fill in empty fields of new transactions and may set the payee or extend notes, but never replace a category or other value you entered. A typed payee name reuses an existing payee regardless of capitalization.
- Split a transaction between categories, as in Actual's mobile editor: choose **Split Transaction**, then give each part an amount, category, and notes. The editor shows the amount left, and a split saves only once its parts add up to the total. Each part uses the transaction's payee unless you give it its own payee or make it a transfer to another account; a transfer part adds and updates its other side, as in Actual. Edit or delete parts later; removing every part makes it an ordinary transaction again, and deleting a split deletes its parts.
- Manage categories and accounts as Actual's mobile menus do. From the **Month actions** menu, add a category group, edit the month's notes, or show hidden categories. Tap a group's name to rename it, edit its notes, hide it, add categories, move it up or down, or delete it, as in Actual's mobile budget. A category's budget editor (**Edit Category**, or touch and hold its row) renames it, edits its notes, hides it, moves it within or between groups, or deletes it. Income categories are listed below expenses. As in Actual, deleting a category or group that has transactions or budgets asks which category receives them. On Accounts, **+** adds an account without a bank connection, on or off budget, with a starting balance. An account's menu renames it, edits its notes, and closes or reopens it: an account with no transactions is deleted, a balance moves to another account (with a category when it leaves your budget), and **Force Close** deletes an account with all its transactions. Closing a bank-linked account unlinks it, as in Actual.
- Manage schedules for bills and income on the **Schedules** tab, as Actual's schedules pages do. Each shows its next date, amount, and status: upcoming, due, missed, paid, or completed. Add or edit one with a name, payee, account, and an exact, approximate, or between amount, on one date or repeating daily, weekly, monthly, or yearly, every so many periods, until a date or a number of times, optionally moved off weekends. The editor previews the next dates, and a schedule can add its transactions automatically. Touch and hold a schedule to post its transaction for the next date or today, skip its next date, complete or restart it, or delete it. Monthly schedules can repeat on specific days, such as the 1st and 15th or the last Friday. A schedule lists its linked transactions and unlinked ones that match it, to link or unlink them. The Schedules tab sets how far ahead registers list upcoming transactions, as Actual's setting does. As in Actual's registers, upcoming scheduled transactions are listed first, with their status; tap one to post it for its date or today, skip its date, or complete a one-time schedule.
- See what needs a category, as in Actual's mobile budget: a banner counts uncategorized transactions and opens them, including split parts, to categorize. A category's budget editor lists its transactions for the month.
- Manage payees and rules from **Settings → Manage**, as Actual's pages do. Rename payees, merge one into another (moving its transactions and rules), delete them, or delete every unused payee. Rules read as sentences; create or edit their stage, conditions (imported payee, payee, account, category, date, notes, amount, inflow or outflow, cleared), and actions (set a field, add to notes, delete the transaction). The editor counts the matching transactions and can apply the rule to them. Rules from schedules, and rules with splits, templates, or tags, stay view only.
- Tag transactions with #tags in their notes, as in Actual; tags show in their colors in the register. **Settings → Manage → Tags** adds tags, finds every #tag already in notes, and renames (also in every note), colors, describes, hides, or deletes them, or lists a tag's transactions. Rules can match tags in notes.
- Import transaction files into an account from its menu (**Import Transactions**): OFX, QFX, QIF, CSV, TSV, or CAMT XML, parsed by Actual. For CSV, choose the columns, separator, header row, date format, and separate inflow and outflow columns; guesses come first, and each account's choices are remembered as Actual remembers them. A preview marks rows matching existing transactions, which importing updates instead of duplicating, and rules run on imported transactions. Payee names are title-cased, as Actual imports them.
- A home-screen widget shows To Budget (or savings) and the categories that need attention, with small, medium, and lock-screen sizes. iOS refreshes the budget in the background now and then, syncing a server budget, so the widget and app stay current. Shortcuts and Siri can add a transaction (amount, payee, account, deposit, notes) or say what is left to budget.
- Formatting follows the budget's settings in Actual: number format, hidden decimals, date format, and the first day of the week. Change them in **Settings → Formatting**; they sync, so Actual web and desktop use them too.
- Transfer money between accounts, as in Actual: choose the other account under **Transfer to/from** in the payee list. Actual adds the linked transaction in that account. Editing either side updates the other's amount, notes, and account; each side keeps its own date and cleared state. Choosing an ordinary payee, or deleting either side, removes the linked transaction. Transfers between two on-budget accounts have no category. Editing or deleting a transfer whose linked transaction is reconciled asks for confirmation first.
- Reconcile an account against your bank's balance, as in Actual's mobile app. Enter the balance, or use the last balance a linked bank reported. Then clear transactions, add an adjustment for any difference, and lock cleared transactions once the balances match. Reconciled transactions show a lock; editing, deleting, or unlocking one asks for confirmation first.
- Sync a server-backed budget before opening it on launch or returning from the background. Returning within five minutes of a successful sync skips it. **Continue offline** shows the saved budget right away while the sync finishes in the background. If sync fails, open the saved budget with a retry message.
- Save edits locally, then sync asynchronously with the server. Transaction edits send only the fields you changed, so they do not overwrite other devices' changes to other fields. Rapid edits are coalesced; **Settings → Sync now** remains available for an immediate retry.
- As in Actual's mobile app, adding, editing, deleting, clearing, and unlocking a transaction show immediately, and the editor closes without waiting for the save. Balances update with them. If a save fails, the change is undone and the register explains why.
- Open end-to-end encrypted budgets using their encryption password.
- Native light/dark appearances, system glass controls, and locale-aware integer-cent entry.
- Amounts use a calculator keypad laid out like Actual's mobile calculator. Enter a number, or a calculation with + − × ÷ and parentheses, such as `120+30` for a category's budget. **=** or leaving the field shows the result. As in Actual, a calculation is rounded to the nearest cent; a single number still may not have more than two decimal places.

A transfer linked to part of a split is edited from the split. Rules for new splits, split rules and rule templates, bank setup, reordering accounts, editing report dashboards and widgets, and custom reports remain in Actual web/desktop. So do targets for income categories in tracking budgets, end-of-month cleanup, checking notes templates, and moving targets back to notes. Existing Actual transaction rules still run through its engine.

Server connection supports password and OpenID sign-in, and one server per installation. After you enter its address, the app offers the sign-in methods your server allows, its active one first. OpenID opens your provider in the system sign-in sheet, so passkeys and existing Safari sign-ins work; your server then returns the session to the app at `actualnative://localhost`. As in Actual, the first OpenID sign-in makes you the server owner and asks for the server password to confirm. Password sign-in stays available unless your server enforces OpenID. Use HTTPS with a valid certificate; HTTP is allowed only for localhost development. Custom certificate trust and periodic syncing while the app is closed are not implemented. Your server password and budget encryption password are separate.

Bank refresh uses connections already set up in Actual web/desktop. Like Actual, a server-backed budget syncs first, so imports match transactions that other devices already imported instead of duplicating them; if that sync fails, the bank is not contacted. Imported transactions are saved on this device and trigger asynchronous budget sync, just like transaction and allocation edits. Reconnect expired bank authorizations in Actual web/desktop. Unlinked and closed accounts refresh locally without contacting a bank.

Failed syncs keep local edits intact and retry on the next edit, app opening, or **Sync now**. Sync is not guaranteed to finish while iOS suspends the app; saved changes remain available for the next attempt. Local/demo budgets stay local.

The budget's default currency code is used when present; otherwise amounts have no currency symbol. Separators and decimals follow the budget's number format; a budget without one follows the device locale.

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
open ActualNative.xcodeproj
```

Select the `ActualNative` scheme and an iOS simulator, then Run. Every Xcode build first runs `scripts/xcode-build-engine.sh`. It bundles Actual and copies its database template, migrations, and license notices, so the app always ships the engine that matches its code. `./scripts/build.sh` builds for the simulator from the command line. If the checkouts are not siblings, prefix commands with `ACTUAL_SOURCE=/absolute/path/to/actual`.

Xcode opened from the Dock does not see your shell's variables or `PATH`. The build looks for Node 22+ in `NODE_BINARY`, Xcode's `PATH`, nvm's default version, Homebrew, and Volta, in that order. It uses the Actual checkout at `ACTUAL_SOURCE`, or `../actual`. If the build cannot find either, create `.xcode.env.local` in this project; git ignores it:

```sh
export NODE_BINARY=/absolute/path/to/node
export ACTUAL_SOURCE=/absolute/path/to/actual
```

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

`./scripts/test-openid.sh` checks OpenID sign-in the same way, against a temporary server with OpenID enabled and a minimal local provider that approves at once. Pass `--simulator SIMULATOR_ID` to run the sign-in UI test on a fresh simulator instead.

Simulator UI checks are in `Tests/UITests`. See [docs/validation.md](docs/validation.md) for the command and observed coverage.

Run `./scripts/test-amounts.sh` for amount entry: localized numbers, calculations, rounding, and invalid input.

Run `./scripts/test-transactions.sh` for register grouping/search regressions and a 10,000-transaction fixture. Optionally pass a local `db.sqlite` path to test it read-only, with `--baseline` to compare the previous section-preparation cost. See the validation notes for the opt-in large-budget simulator test.

Run `./scripts/test-bank-sync.sh` for native bank-import regressions using a disposable local HTTP fixture. It checks account selection, SimpleFIN batching, exact amounts, duplicate prevention, rules/preferences, partial failures, authentication errors, retries, and persistence. No live bank credentials are used.

Run `./scripts/test-auto-sync.sh` after building the upstream core/API/server artifacts listed above. It uses an encrypted disposable budget and a local proxy to hold or reject sync responses, verifying opening sync, local saves during network waits, automatic uploads, offline restart/retry, concurrent edits from another device, rejected snapshot uploads, and safe budget switching.

## Implementation and storage

SwiftUI owns the visible UI. `Engine/entry.ts` exposes a small command interface to Actual's pinned handlers. `Native/Core` supplies SQLite, sandboxed files, URLSession HTTP, cryptography, timers, and a serial JavaScriptCore runtime. Tracked budget sync releases the command queue during network waits; Actual serializes incoming changes, local mutations, and coherent reads. The app loads the budget month, the accounts overview, and the transaction register as separate requests. A month change or allocation reloads only the month, and results are decoded off the main thread. The minified engine also loads off the main thread. Budget/server switching waits for active sync. The engine is the sole budget writer; amounts cross the bridge as exact integer cents. Actual's desktop backup service, which copies the budget every 15 minutes, is disabled, as in Actual's web and mobile apps.

Downloaded budget data is stored locally as SQLite in the app sandbox, using iOS data protection; the local database is not separately encrypted by this app. Server tokens and imported encryption keys are in Keychain; other engine settings are in a protected `settings.json` file, and the Keychain is only rewritten when credentials change. Earlier builds kept every setting in the Keychain, and they move automatically. Actual's optional end-to-end encryption protects synced budget data using its existing format. The app never sends data to a separate intermediary service.

Future upstream revisions require adapter review and rerunning the integration checks. Newer-schema changes that cannot be applied trigger an update warning and block edits. If Actual discards another device's change, this build pauses edits and sync for that budget and explains that devices may show different values. **Keep using this budget** resumes them, as Actual itself continues after this warning. Keep a backup before trying this development client with a real budget.

Actual Budget and bundled dependencies retain their original licenses. The build includes `Actual-LICENSE.txt` and `ThirdPartyNotices.txt` in its resources. This project is unofficial and is not an Actual Budget release.
