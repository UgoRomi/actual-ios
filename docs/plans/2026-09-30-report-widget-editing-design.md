# Editing report widgets

Follow how Actual saves a dashboard widget at the revision in `Engine/upstream.json`. Its report pages (`desktop-client/src/components/reports/reports/NetWorth.tsx`, `CashFlow.tsx`, `Spending.tsx`, `Summary.tsx`, `Calendar.tsx`) have a **Save widget** button, and its cards (`ReportCard.tsx`, `MarkdownCard.tsx`) have a menu to rename a widget or edit a text widget. Each writes the widget's whole `meta` with loot-core's `dashboard-update-widget`, spreading the saved meta first. Filters are rule conditions from `filters/FiltersMenu.tsx`; ranges are `TimeFrame`s from `Header.tsx` and `dateRangePresets.ts`.

## What can be edited

The widgets this app draws: net worth, cash flow, spending analysis, summary, calendar, and text.

- **Name**: a cleared name becomes Actual's default for the widget.
- **Range** (not spending): Actual's quick-select presets, the last so many months ending with the current one, or fixed months. A saved range that none of these describes, such as a number of days, is shown in words and kept until another is chosen.
- **Filters**: conditions matching all or any, on the fields Actual's filter menu offers: date, account, payee, notes, category, category group, amount (any, inflow, or outflow), cleared, reconciled, and transfer. Spending has no date filter, as in Actual. The rule editor's condition editor is shared. Conditions with options this app does not edit (month or year dates, named conditions) are listed, kept, and can be removed.
- **Net worth**: interval and trend or stacked graph.
- **Cash flow**: whether its page shows the balance.
- **Spending**: the month (the current month, or a chosen one), what it is compared with (another month, the budget, or an average), and the average's range.
- **Summary**: how it shows (sum, average per month, year, or transaction, or percentage); a percentage's divisor filters and whether it divides by all time.
- **Text**: its Markdown and position.

Adding, removing, copying, resizing, and arranging widgets, managing dashboards, custom reports, and the other widget kinds remain in Actual web/desktop.

## Where

- Touch and hold a widget on the dashboard and choose **Edit Widget** (or **Edit Text**), as a card's menu does in Actual. A report's page also has **Edit**.
- A report's page still tries out another range, interval, balance line, or comparison without saving. When it shows something other than the widget's own, **Save to Widget** saves those choices, as Actual's **Save widget** saves what its page shows.

## Engine

`Engine/report-editing.ts`:

- `reportSettings`: one widget's settings with Actual's defaults filled in, read when the editor opens. Its range is evaluated today with `calculateTimeRange`, as Actual's pages open.
- `saveReportWidget`: the settings that changed. The engine reads the widget again, merges them into its meta, and sends `dashboard-update-widget`, so settings this app does not know, the summary's font size, and anything changed on another device since are kept. Each setting is validated; filters must be ones Actual can run (`make-filters-from-conditions`). A chosen range is stored as Actual's page holds it after choosing it: evaluated once.

A spending widget without a saved `compare` month follows the current month; Actual pins the month once its page saves. Here the month is pinned only when one is chosen, and choosing **Current month** removes it.

The app reloads reports after a save (`dataRevision`) and starts a sync, like other edits.

## Implementation plan

1. Engine commands, wired into `entry.ts` with the write guard; strict typecheck.
2. Native models (`ReportWidgetSettings`, `ReportRangeDraft`), `AppModel` calls, the editor, the cards' menu, and the pages' **Edit** and **Save to Widget**.
3. Engine test editing every kind of widget on the demo budget, checking the stored meta and the report it then produces; the sync test sees a widget edit through Actual's API; a demo UI test.
4. README and validation notes.

## Delivered behavior

As designed. See `../validation.md`.
