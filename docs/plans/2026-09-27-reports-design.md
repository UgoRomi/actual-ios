# Reports

Follow Actual's reports at the revision in `Engine/upstream.json`: `desktop-client/src/components/reports/Overview.tsx`, `ReportsDashboardRouter.tsx`, `reportRanges.ts`, `dateRangePresets.ts`, the cards and pages in `reports/reports/`, and the calculations in `reports/spreadsheets/` (`net-worth-spreadsheet.ts`, `cash-flow-spreadsheet.tsx`, `spending-spreadsheet.ts`, `summary-spreadsheet.ts`, `calendar-spreadsheet.ts`). Dashboards and widgets are loot-core's `dashboard_pages` and `dashboard` tables.

A **Reports** tab shows the budget's dashboards as Actual's mobile web app does: read-only, one column, widgets ordered top to bottom and then left to right, with a picker when there is more than one dashboard. It opens the first dashboard, as Actual does.

Widgets drawn natively, with Swift Charts:

- **Net worth**: net worth at the end of the range, its change, and a trend or per-account stacked graph, by the widget's interval.
- **Cash flow**: income and expenses for the range. The detail page shows income, expenses, and transfers by day, or by month for ranges over three months, with the running balance.
- **Spending analysis**: cumulative spending through the month against the previous month, the budget, or an average, with the difference to date.
- **Summary**: a sum, average per month, year, or transaction, or a percentage, shown as Actual does: absolute value, colored by sign.
- **Calendar**: income and expenses per day for each month. Choosing a day lists its transactions.
- **Text**: the widget's Markdown.

These are every kind of widget in Actual's default dashboard. Custom reports, age of money, and crossover point show their name and a note to open them in Actual web or desktop. Experimental widgets appear only when their Actual feature flag is on, as upstream does, with the same note.

Each widget's saved filters, time frame, and options apply. The engine reads the widget itself, so native code never rebuilds its filters. Time frames are evaluated with upstream's `calculateTimeRange`, so a live range slides to the current month. A detail page may try another range from Actual's quick-select presets (3 months, 6 months, 1 year, year to date, last month, last year, prior year to date, current quarter, previous quarter, all time), and spending analysis may switch between comparing with last month, the budget, or the average. These choices are not saved; editing dashboards and widgets remains in Actual web/desktop.

## Engine

`Engine/reports.ts` ports the client-side calculations. They run under Actual's mutation lock, like the other reads, and return exact integer minor units. Upstream averages and daily budgets are fractional; the port rounds them when returning, as Actual rounds them for display. Dates are returned as ISO days or months; the app formats them.

- `reportsDashboard`: pages, widgets with type, name, and position, feature flags for experimental widgets, and custom report names.
- `report`: one widget's data, given its ID and optional `timeFrame`, `interval`, and `detail` choices. Spending returns every comparison, so switching comparisons needs no new request.
- `reportTransactions`: the transactions matching a calendar widget's filters on one day.

## Implementation plan

1. Engine port, wired into `entry.ts`; strict typecheck.
2. Native models, `AppModel` calls, Reports tab, cards, and detail pages.
3. Engine test comparing every widget's values with direct SQL on the demo budget, including filters and each range mode. Demo UI test that opens every card's detail.
4. README and validation notes.

## Delivered behavior

As designed. The engine returns every widget's data with Actual's calculations, checked against direct SQL on the demo's default dashboard, and the app reloads reports after edits, syncs, and bank refreshes. `ReportDate.range` labels ranges like `DateRange.tsx`. Detail pages also let net worth switch between daily, weekly, monthly, and yearly intervals, as its page in Actual does. See `../validation.md`.

As a native difference, calendar, summary, and spending leave out off-budget accounts and transfers to or from them unless the app passes `includeOffBudget`, or the widget's filters choose an off-budget account. See `../validation.md`.
