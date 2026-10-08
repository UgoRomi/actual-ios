import Charts
import SwiftUI

/// The budget's report dashboards in one column, as in Actual's mobile web app, or in rows where there is room.
/// Touching and holding a widget edits its saved settings.
struct ReportsView: View {
    @Environment(AppModel.self) private var model
    @State private var dashboard: ReportsDashboard?
    @State private var pageID: String?
    @State private var error: String?
    @State private var columnCount = 1

    private func rows(_ widgets: [ReportWidget]) -> [[ReportWidget]] {
        stride(from: 0, to: widgets.count, by: columnCount).map { Array(widgets[$0..<min($0 + columnCount, widgets.count)]) }
    }

    private var page: DashboardPage? {
        dashboard?.pages.first { $0.id == pageID } ?? dashboard?.pages.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error { ErrorNotice(message: error) { Task { await load() } } }
                    if let page, let dashboard {
                        if page.widgets.isEmpty {
                            ContentUnavailableView("No reports on this dashboard", systemImage: "chart.bar.xaxis",
                                                   description: Text("Add widgets to this dashboard in Actual web or desktop."))
                        }
                        // Rows of widgets where there is room, as Actual's desktop dashboard lays them out.
                        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                            ForEach(rows(page.widgets), id: \.first?.id) { row in
                                GridRow(alignment: .top) {
                                    ForEach(row) { widget in
                                        ReportCard(widget: widget, earliestMonth: dashboard.earliestMonth)
                                    }
                                    // Keeps a short last row's widgets the width of the others.
                                    ForEach(row.count..<columnCount, id: \.self) { _ in Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                                }
                            }
                        }
                        if !page.widgets.isEmpty {
                            Text("Touch and hold a widget to edit it. Add, remove, and arrange widgets in Actual web or desktop.")
                                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                    } else if error == nil {
                        ProgressView("Loading reports…").frame(maxWidth: .infinity, minHeight: 200)
                    }
                    SyncFooter()
                }.padding(20).frame(maxWidth: columnCount == 1 ? 760 : .infinity).frame(maxWidth: .infinity)
            }
            .onGeometryChange(for: Int.self) { proxy in
                // Widgets at least 320 points wide, up to three across.
                min(3, max(1, Int((proxy.size.width - 24) / 336)))
            } action: { columnCount = $0 }
            .background(ActualTheme.background)
            .navigationTitle("Reports")
            .toolbar {
                if let pages = dashboard?.pages, pages.count > 1 {
                    ToolbarItem(placement: .topBarLeading) { dashboardPicker(pages) }
                }
                ToolbarItem(placement: .topBarTrailing) { SettingsButton() }
            }
            .refreshable { await model.refresh(); await load() }
            .task(id: model.dataRevision) { await load() }
            .navigationDestination(for: ReportRoute.self) { route in
                ReportDetailView(widget: route.widget, earliestMonth: route.earliestMonth)
            }
        }
    }

    private func dashboardPicker(_ pages: [DashboardPage]) -> some View {
        Menu {
            Picker("Dashboard", selection: Binding(get: { page?.id }, set: { pageID = $0 })) {
                ForEach(pages) { page in Text(page.name.isEmpty ? "Dashboard" : page.name).tag(Optional(page.id)) }
            }
        } label: {
            Label(page?.name ?? "Dashboard", systemImage: "square.grid.2x2")
        }
        .accessibilityLabel("Dashboard")
    }

    private func load() async {
        do {
            dashboard = try await model.reportsDashboard()
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ReportRoute: Hashable {
    let widget: ReportWidget
    let earliestMonth: String
}

/// One widget on the dashboard. Reports open their detail page; touching and
/// holding a widget offers its editor, as a card's menu does in Actual.
struct ReportCard: View {
    let widget: ReportWidget
    let earliestMonth: String
    @Environment(AppModel.self) private var model
    @State private var data: ReportData?
    @State private var error: String?
    @State private var isEditing = false

    var body: some View {
        card
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 22))
            .contextMenu {
                if widget.isEditable {
                    Button(widget.editTitle, systemImage: "slider.horizontal.3") { isEditing = true }
                }
            }
            .sheet(isPresented: $isEditing) { ReportWidgetEditor(widget: widget, earliestMonth: earliestMonth) }
    }

    @ViewBuilder private var card: some View {
        switch widget.kind {
        case .markdown:
            MarkdownBlocks(content: widget.content ?? "", alignment: widget.textAlign ?? "left")
                .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ActualTheme.surface, in: RoundedRectangle(cornerRadius: 22))
        case .other:
            ReportCardFrame(title: widget.title, subtitle: nil) {
                Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary)
            } content: {
                Text("Open this report in Actual web or desktop.").font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        default:
            NavigationLink(value: ReportRoute(widget: widget, earliestMonth: earliestMonth)) {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Open report")
            .task(id: model.dataRevision) { await load() }
        }
    }

    @ViewBuilder private var content: some View {
        let currency = model.currency
        if let report = data?.netWorth {
            ReportCardFrame(title: widget.title, subtitle: ReportDate.range(report.start, report.end)) {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(Money.formatted(report.netWorth, currency: currency)).font(.headline).monospacedDigit()
                    ChangeText(amount: report.totalChange, currency: currency)
                }
            } content: {
                NetWorthChart(report: report, currency: currency, compact: true).frame(height: 120)
            }
        } else if let report = data?.cashFlow {
            ReportCardFrame(title: widget.title, subtitle: ReportDate.range(report.start, report.end)) {
                ChangeText(amount: report.income + report.expense, currency: currency)
            } content: {
                CashFlowTotals(income: report.income, expense: report.expense, currency: currency)
            }
        } else if let report = data?.spending {
            ReportCardFrame(title: widget.title, subtitle: SpendingText.comparison(report, mode: report.mode)) {
                let difference = report.difference(report.mode) ?? 0
                // More spent than the comparison shows in red, as in Actual.
                Text((difference > 0 ? "+" : "") + Money.formatted(difference, currency: currency))
                    .font(.headline).monospacedDigit().foregroundStyle(ReportColor.of(-difference))
            } content: {
                SpendingChart(report: report, mode: report.mode, currency: currency, compact: true).frame(height: 120)
            }
        } else if let report = data?.summary {
            ReportCardFrame(title: widget.title, subtitle: ReportDate.range(report.start, report.end)) {
                EmptyView()
            } content: {
                SummaryValue(report: report, currency: currency)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
            }
        } else if let report = data?.calendar {
            ReportCardFrame(title: widget.title, subtitle: ReportDate.range(report.start, report.end)) {
                CalendarTotals(report: report, currency: currency)
            } content: {
                if let month = report.months.last {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ReportDate.month(month.month, style: .wide)).font(.subheadline.weight(.medium))
                        CalendarMonthGrid(month: month, firstDayOfWeekIdx: report.firstDayOfWeekIdx, compact: true,
                                          currency: currency)
                    }
                }
            }
        } else {
            ReportCardFrame(title: widget.title, subtitle: nil) { EmptyView() } content: {
                ReportPlaceholder(error: error) { Task { await load() } }
            }
        }
    }

    private func load() async {
        do {
            data = try await model.report(widget.id)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The cash flow card's income and expense bars.
struct CashFlowTotals: View {
    let income: Int
    let expense: Int
    let currency: String
    var body: some View {
        let largest = max(income, -expense, 1)
        VStack(alignment: .leading, spacing: 10) {
            bar("Income", income, largest, ReportColor.positive)
            bar("Expenses", -expense, largest, ReportColor.negative)
        }
    }

    private func bar(_ label: String, _ amount: Int, _ largest: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(Money.formatted(amount, currency: currency)).font(.subheadline).monospacedDigit()
            }
            GeometryReader { proxy in
                Capsule().fill(color.gradient)
                    .frame(width: max(proxy.size.width * Double(amount) / Double(largest), amount > 0 ? 4 : 0))
            }.frame(height: 10)
        }
        .accessibilityElement(children: .combine)
    }
}

/// SummaryNumber.tsx: the absolute value, colored by sign, with % for percentages.
struct SummaryValue: View {
    let report: SummaryReport
    let currency: String
    var body: some View {
        let total = report.total ?? 0
        Group {
            if report.total == nil {
                Text("—")
            } else if report.type == "percentage" {
                Text(abs(total).formatted(.number.precision(.fractionLength(0...2))) + "%")
            } else {
                Text(Money.formatted(abs(Int(total)), currency: currency))
            }
        }
        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.4)
        .foregroundStyle(total > 0 ? ReportColor.positive : total < 0 ? ReportColor.negative : ReportColor.neutral)
        .accessibilityLabel(report.total == nil ? "Unknown amount"
                            : total == 0 ? "Zero amount" : total < 0 ? "Negative amount" : "Positive amount")
        .accessibilityValue(report.type == "percentage"
                            ? abs(total).formatted(.number.precision(.fractionLength(0...2))) + "%"
                            : Money.formatted(abs(Int(total)), currency: currency))
    }
}

/// A calendar report's income and spending for its whole range.
struct CalendarTotals: View {
    let report: CalendarReport
    let currency: String
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(Money.formatted(report.months.reduce(0) { $0 + $1.totalIncome }, currency: currency))
                .foregroundStyle(ReportColor.positive)
            Text(Money.formatted(-report.months.reduce(0) { $0 + $1.totalExpense }, currency: currency))
                .foregroundStyle(ReportColor.negative)
        }
        .font(.subheadline.weight(.medium)).monospacedDigit()
        .accessibilityElement(children: .combine)
    }
}

enum SpendingText {
    /// DateRange.tsx for spending: "Compare Sep 2026 to Aug 2026", or to the budget or average.
    static func comparison(_ report: SpendingReport, mode: SpendingReport.Mode) -> String {
        let target = switch mode {
        case .singleMonth: ReportDate.month(report.compareTo)
        case .budget: "budgeted"
        case .average: report.averageRange.title
        }
        return "Compare \(ReportDate.month(report.compare)) to \(target)"
    }

    static func comparisonName(_ report: SpendingReport, mode: SpendingReport.Mode) -> String {
        switch mode {
        case .singleMonth: ReportDate.month(report.compareTo)
        case .budget: "Budgeted"
        case .average: "Average (\(report.averageRange.title))"
        }
    }
}

/// Net worth over the range: a trend line, or each account's balance stacked.
struct NetWorthChart: View {
    let report: NetWorthReport
    let currency: String
    var compact = false
    @State private var selectedDate: Date?

    private var stacked: Bool { report.mode == "stacked" && !compact }

    var body: some View {
        let selected = selectedIndex
        Chart {
            if stacked {
                ForEach(report.accounts) { account in
                    ForEach(report.points) { point in
                        AreaMark(x: .value("Date", ReportDate.date(point.date) ?? .distantPast),
                                 y: .value("Balance", ChartAmount.value(point.balances[account.id] ?? 0)),
                                 stacking: .standard)
                        .foregroundStyle(by: .value("Account", account.name))
                    }
                }
            } else {
                ForEach(report.points) { point in
                    AreaMark(x: .value("Date", ReportDate.date(point.date) ?? .distantPast),
                             y: .value("Net worth", ChartAmount.value(point.total)))
                    .foregroundStyle(ActualTheme.accent.opacity(0.18).gradient)
                    .interpolationMethod(.monotone)
                    LineMark(x: .value("Date", ReportDate.date(point.date) ?? .distantPast),
                             y: .value("Net worth", ChartAmount.value(point.total)))
                    .foregroundStyle(ActualTheme.accent)
                    .interpolationMethod(.monotone)
                }
            }
            if let selected {
                let point = report.points[selected]
                let date = ReportDate.date(point.date) ?? .distantPast
                if !stacked {
                    PointMark(x: .value("Date", date), y: .value("Net worth", ChartAmount.value(point.total)))
                        .foregroundStyle(ActualTheme.accent)
                }
                RuleMark(x: .value("Date", date))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .annotation(position: ChartCallout.side(selected, of: report.points.count), alignment: .top,
                                spacing: 6, overflowResolution: ChartCallout.overflow) {
                        callout(selected)
                    }
            }
        }
        .chartLegend(compact ? .hidden : .automatic)
        .chartXAxis(compact ? .hidden : .automatic)
        .amountAxis(currency: currency)
        .chartYAxis(compact ? .hidden : .automatic)
        .chartSelection($selectedDate, enabled: !compact)
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityLabel("Net worth chart")
    }

    /// The point nearest the finger.
    private var selectedIndex: Int? {
        guard let selectedDate else { return nil }
        return report.points.indices.min { a, b in
            distance(report.points[a], selectedDate) < distance(report.points[b], selectedDate)
        }
    }

    private func distance(_ point: NetWorthReport.Point, _ date: Date) -> TimeInterval {
        abs((ReportDate.date(point.date) ?? .distantPast).timeIntervalSince(date))
    }

    /// NetWorthGraph.tsx tooltips: assets, debt, net worth, and change; or each account when stacked.
    private func callout(_ index: Int) -> ChartCallout {
        let point = report.points[index]
        let title = ReportDate.period(point.date, interval: report.interval)
        if stacked {
            let balances = report.accounts
                .compactMap { account in point.balances[account.id].map { (name: account.name, amount: $0) } }
                .filter { $0.amount != 0 }
                .sorted { $0.amount > $1.amount }
            let shown = 6, hidden = balances.count - shown
            let rows = balances.prefix(shown).map { ChartCalloutRow(label: $0.name, amount: $0.amount) }
                + [ChartCalloutRow(label: "Net worth", amount: point.total, emphasized: true)]
            return ChartCallout(title: title, rows: rows, currency: currency,
                                footnote: hidden > 0 ? "\(hidden) more account\(hidden == 1 ? "" : "s")" : nil)
        }
        var rows = [
            ChartCalloutRow(label: "Assets", amount: point.assets),
            ChartCalloutRow(label: "Debt", amount: point.debt),
            ChartCalloutRow(label: "Net worth", amount: point.total, emphasized: true),
        ]
        if index > 0 { rows.append(ChartCalloutRow(label: "Change", amount: point.total - report.points[index - 1].total)) }
        return ChartCallout(title: title, rows: rows, currency: currency)
    }
}

/// Cumulative spending through the month against the chosen comparison.
struct SpendingChart: View {
    let report: SpendingReport
    let mode: SpendingReport.Mode
    let currency: String
    var compact = false
    @State private var selectedDay: Int?

    var body: some View {
        let compareName = ReportDate.month(report.compare)
        let otherName = SpendingText.comparisonName(report, mode: mode)
        let selected = selectedDay.flatMap { day in report.days.first { $0.day == min(max(day, 1), 28) } }
        Chart {
            ForEach(report.days) { day in
                if let value = day.value(mode) {
                    LineMark(x: .value("Day", day.day), y: .value("Spent", ChartAmount.value(-value)),
                             series: .value("Series", otherName))
                    .foregroundStyle(by: .value("Series", otherName))
                    .interpolationMethod(.monotone)
                }
                if let value = day.compare {
                    LineMark(x: .value("Day", day.day), y: .value("Spent", ChartAmount.value(-value)),
                             series: .value("Series", compareName))
                    .foregroundStyle(by: .value("Series", compareName))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 3))
                }
            }
            if let selected {
                if let value = selected.value(mode) {
                    PointMark(x: .value("Day", selected.day), y: .value("Spent", ChartAmount.value(-value)))
                        .foregroundStyle(ReportColor.comparison)
                }
                if let value = selected.compare {
                    PointMark(x: .value("Day", selected.day), y: .value("Spent", ChartAmount.value(-value)))
                        .foregroundStyle(ActualTheme.accent)
                }
                RuleMark(x: .value("Day", selected.day))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .annotation(position: ChartCallout.side(selected.day - 1, of: 28), alignment: .top,
                                spacing: 6, overflowResolution: ChartCallout.overflow) {
                        callout(selected, compareName: compareName, otherName: otherName)
                    }
            }
        }
        .chartForegroundStyleScale([compareName: ActualTheme.accent, otherName: ReportColor.comparison])
        .chartXScale(domain: 1...28)
        .chartLegend(compact ? .hidden : .automatic)
        .chartXAxis(compact ? .hidden : .automatic)
        .amountAxis(currency: currency)
        .chartYAxis(compact ? .hidden : .automatic)
        .chartSelection($selectedDay, enabled: !compact)
        .sensoryFeedback(.selection, trigger: selected?.day)
        .accessibilityLabel("Spending chart")
    }

    /// SpendingGraph.tsx tooltip: spending through the day in each month, and the difference.
    private func callout(_ day: SpendingReport.Day, compareName: String, otherName: String) -> ChartCallout {
        let compare = day.compare.map { -$0 }, other = day.value(mode).map { -$0 }
        var rows: [ChartCalloutRow] = []
        if let compare { rows.append(ChartCalloutRow(label: compareName, amount: compare, color: ActualTheme.accent)) }
        if let other { rows.append(ChartCalloutRow(label: otherName, amount: other, color: ReportColor.comparison)) }
        if let compare, let other {
            // More spent than the comparison shows in red, as on the card.
            let difference = compare - other
            rows.append(ChartCalloutRow(label: difference > 0 ? "Spent more" : difference < 0 ? "Spent less" : "Difference",
                                        amount: abs(difference), emphasized: true))
        }
        return ChartCallout(title: day.day >= 28 ? "Day 28+" : "Day \(day.day)", rows: rows, currency: currency)
    }
}
