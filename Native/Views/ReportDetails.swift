import Charts
import SwiftUI

/// A report's page. Ranges and options chosen here are not saved to the widget,
/// as Actual keeps them until you save the widget, which this app leaves to Actual.
struct ReportDetailView: View {
    let widget: ReportWidget
    let earliestMonth: String
    @Environment(AppModel.self) private var model
    @State private var preset: ReportRangePreset?
    @State private var interval: String?
    @State private var data: ReportData?
    @State private var error: String?

    private struct Request: Equatable { let preset: ReportRangePreset?; let interval: String?; let revision: Int }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if widget.kind != .spending {
                    ReportRangeMenu(preset: $preset, oneMonth: [.cashFlow, .summary, .calendar].contains(widget.kind))
                }
                if let data {
                    content(data)
                } else {
                    ReportPlaceholder(error: error, height: 240) { Task { await load() } }
                }
            }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .background(ActualTheme.background)
        .navigationTitle(widget.title).navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: Request(preset: preset, interval: interval, revision: model.dataRevision)) { await load() }
    }

    @ViewBuilder private func content(_ data: ReportData) -> some View {
        let currency = model.currency
        if let report = data.netWorth {
            NetWorthDetail(report: report, currency: currency, interval: $interval)
        } else if let report = data.cashFlow {
            CashFlowDetail(report: report, currency: currency)
        } else if let report = data.spending {
            SpendingDetail(report: report, currency: currency)
        } else if let report = data.summary {
            SummaryDetail(report: report, currency: currency)
        } else if let report = data.calendar {
            CalendarDetail(widgetID: widget.id, report: report, currency: currency)
        }
    }

    private func load() async {
        do {
            data = try await model.report(
                widget.id, timeFrame: preset?.timeFrame(earliestMonth: earliestMonth), interval: interval,
                detail: widget.kind == .cashFlow)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A labeled amount in a detail page's totals.
private struct TotalRow: View {
    let label: String
    let amount: Int
    let currency: String
    var color: Color = .primary
    var body: some View {
        LabeledContent(label) {
            Text(Money.formatted(amount, currency: currency)).monospacedDigit().foregroundStyle(color)
        }
    }
}

private struct DetailSection<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(ActualTheme.surface, in: RoundedRectangle(cornerRadius: 22))
    }
}

private struct NetWorthDetail: View {
    let report: NetWorthReport
    let currency: String
    @Binding var interval: String?

    var body: some View {
        DetailSection {
            Text(ReportDate.range(report.start, report.end)).font(.subheadline).foregroundStyle(.secondary)
            Text(Money.formatted(report.netWorth, currency: currency))
                .font(.system(.largeTitle, design: .rounded, weight: .bold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
            ChangeText(amount: report.totalChange, currency: currency)
            Picker("Interval", selection: Binding(get: { interval ?? report.interval }, set: { interval = $0 })) {
                ForEach(["Daily", "Weekly", "Monthly", "Yearly"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented)
            NetWorthChart(report: report, currency: currency).frame(height: 260)
        }
        DetailSection {
            ForEach(Array(report.points.enumerated().reversed()), id: \.element.id) { index, point in
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Money.formatted(point.total, currency: currency)).monospacedDigit()
                        if index > 0 { ChangeText(amount: point.total - report.points[index - 1].total, currency: currency) }
                    }
                } label: {
                    Text(label(point.date))
                }
                if index > 0 { Divider() }
            }
        }
        Text("Net worth shows the balance of all accounts over time, including all of your investments. Your “net worth” is considered to be the amount you’d have if you sold all your assets and paid off as much debt as possible.")
            .font(.footnote).foregroundStyle(.secondary)
    }

    private func label(_ date: String) -> String {
        guard let value = ReportDate.date(date) else { return date }
        switch report.interval {
        case "Daily": return value.formatted(date: .abbreviated, time: .omitted)
        case "Weekly": return "Week of " + value.formatted(date: .abbreviated, time: .omitted)
        case "Yearly": return value.formatted(.dateTime.year())
        default: return value.formatted(.dateTime.month(.wide).year())
        }
    }
}

private struct CashFlowDetail: View {
    let report: CashFlowReport
    let currency: String
    @State private var showBalance: Bool?

    var body: some View {
        let detail = report.detail
        let balance = showBalance ?? report.showBalance
        DetailSection {
            Text(ReportDate.range(report.start, report.end)).font(.subheadline).foregroundStyle(.secondary)
            if let detail {
                TotalRow(label: "Income", amount: detail.totalIncome, currency: currency, color: ReportColor.positive)
                TotalRow(label: "Expenses", amount: detail.totalExpenses, currency: currency, color: ReportColor.negative)
                TotalRow(label: "Transfers", amount: detail.totalTransfers, currency: currency)
                Divider()
                LabeledContent("Change") {
                    ChangeText(amount: detail.totalIncome + detail.totalExpenses, currency: currency)
                }
                TotalRow(label: "Balance", amount: detail.balance, currency: currency)
            }
        }
        if let detail {
            DetailSection {
                Toggle("Show balance", isOn: Binding(get: { balance }, set: { showBalance = $0 }))
                Chart {
                    ForEach(detail.points) { point in
                        let date = ReportDate.date(point.date) ?? .distantPast
                        let unit: Calendar.Component = detail.isConcise ? .month : .day
                        BarMark(x: .value("Date", date, unit: unit), y: .value("Amount", ChartAmount.value(point.income)))
                            .foregroundStyle(by: .value("Kind", "Income"))
                        BarMark(x: .value("Date", date, unit: unit), y: .value("Amount", ChartAmount.value(point.expense)))
                            .foregroundStyle(by: .value("Kind", "Expenses"))
                        if point.transfers != 0 {
                            BarMark(x: .value("Date", date, unit: unit), y: .value("Amount", ChartAmount.value(point.transfers)))
                                .foregroundStyle(by: .value("Kind", "Transfers"))
                        }
                        if balance {
                            LineMark(x: .value("Date", date, unit: unit), y: .value("Balance", ChartAmount.value(point.balance)))
                                .foregroundStyle(by: .value("Kind", "Balance"))
                        }
                    }
                }
                .chartForegroundStyleScale([
                    "Income": ReportColor.positive, "Expenses": ReportColor.negative,
                    "Transfers": ReportColor.comparison, "Balance": ActualTheme.accent,
                ])
                .amountAxis(currency: currency)
                .frame(height: 280)
                .accessibilityLabel("Cash flow chart")
            }
            Text(detail.isConcise ? "Shown by month." : "Shown by day, through today.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct SpendingDetail: View {
    let report: SpendingReport
    let currency: String
    @State private var mode: SpendingReport.Mode?

    var body: some View {
        let mode = self.mode ?? report.mode
        let day = report.days.indices.contains(report.todayIndex) ? report.days[report.todayIndex] : nil
        let toDate = report.compare == BudgetDate.month(Date()) ? " to date" : ""
        DetailSection {
            Picker("Compare to", selection: Binding(get: { mode }, set: { self.mode = $0 })) {
                ForEach(SpendingReport.Mode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Text(SpendingText.comparison(report, mode: mode)).font(.subheadline).foregroundStyle(.secondary)
            SpendingChart(report: report, mode: mode, currency: currency).frame(height: 260)
        }
        DetailSection {
            if let day {
                TotalRow(label: "Spent \(ReportDate.month(report.compare))\(toDate)", amount: abs(day.compare ?? 0),
                         currency: currency)
                switch mode {
                case .singleMonth:
                    TotalRow(label: "Spent \(ReportDate.month(report.compareTo))\(toDate)", amount: abs(day.compareTo ?? 0),
                             currency: currency)
                case .budget:
                    TotalRow(label: "Budgeted\(toDate)", amount: abs(day.budget), currency: currency)
                case .average:
                    TotalRow(label: "Average\(toDate) (\(report.averageRange.title))", amount: abs(day.average),
                             currency: currency)
                }
                Divider()
                let difference = report.difference(mode) ?? 0
                LabeledContent(difference > 0 ? "Spent more" : difference < 0 ? "Spent less" : "Difference") {
                    Text(Money.formatted(abs(difference), currency: currency)).monospacedDigit()
                        .foregroundStyle(ReportColor.of(-difference))
                }
            }
        }
        Text("Days after the 28th count toward the 28th, so months of any length compare.")
            .font(.footnote).foregroundStyle(.secondary)
    }
}

private struct SummaryDetail: View {
    let report: SummaryReport
    let currency: String

    var body: some View {
        DetailSection {
            Text(ReportDate.range(report.start, report.end)).font(.subheadline).foregroundStyle(.secondary)
            SummaryValue(report: report, currency: currency)
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
            if report.type != "sum" {
                Divider()
                TotalRow(label: "Total", amount: report.dividend, currency: currency)
                LabeledContent(divisorLabel) { Text(divisor).monospacedDigit() }
            }
        }
        Text(explanation).font(.footnote).foregroundStyle(.secondary)
    }

    private var divisorLabel: String {
        switch report.type {
        case "avgPerMonth": "Months"
        case "avgPerYear": "Years"
        case "avgPerTransact": "Transactions"
        default: report.divisorAllTime ? "Divided by (all time)" : "Divided by"
        }
    }

    /// Summary.tsx: counts as numbers, a percentage's base as an amount.
    private var divisor: String {
        report.type == "percentage"
            ? Money.formatted(Int(report.divisor.rounded()), currency: currency)
            : report.divisor.formatted(.number.precision(.fractionLength(0...2)))
    }

    private var explanation: String {
        switch report.type {
        case "avgPerMonth": "The total divided by the months in the range, counting the elapsed part of the last month."
        case "avgPerYear": "The total divided by the years in the range."
        case "avgPerTransact": "The total divided by the number of transactions."
        case "percentage": "The total as a percentage of the amount it is divided by."
        default: "The total of the transactions this widget’s filters match."
        }
    }
}

private struct CalendarDetail: View {
    let widgetID: String
    let report: CalendarReport
    let currency: String
    @Environment(AppModel.self) private var model
    @State private var selectedDate: String?
    @State private var transactions: [ReportTransaction]?
    @State private var error: String?

    var body: some View {
        ForEach(report.months.reversed()) { month in
            DetailSection {
                HStack(alignment: .firstTextBaseline) {
                    Text(ReportDate.month(month.month, style: .wide)).font(.headline)
                    Spacer()
                    Text(Money.formatted(month.totalIncome, currency: currency)).foregroundStyle(ReportColor.positive)
                    Text(Money.formatted(-month.totalExpense, currency: currency)).foregroundStyle(ReportColor.negative)
                }.font(.subheadline).monospacedDigit()
                CalendarMonthGrid(month: month, firstDayOfWeekIdx: report.firstDayOfWeekIdx, currency: currency,
                                  selectedDate: selectedDate) { date in
                    selectedDate = date
                }
                if let selectedDate, selectedDate.hasPrefix(month.month) { dayTransactions(selectedDate) }
            }
        }
        .task(id: selectedDate) { await loadDay() }
    }

    @ViewBuilder private func dayTransactions(_ date: String) -> some View {
        Divider()
        Text(ReportDate.date(date)?.formatted(date: .complete, time: .omitted) ?? date).font(.subheadline.weight(.semibold))
        if let error {
            Text(error).font(.footnote).foregroundStyle(.secondary)
        } else if let transactions {
            if transactions.isEmpty { Text("No transactions").font(.footnote).foregroundStyle(.secondary) }
            ForEach(transactions) { transaction in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(transaction.payeeName ?? "No payee")
                        Text([transaction.categoryName, transaction.accountName].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    MoneyText(value: transaction.amount, currency: currency, positiveColor: ReportColor.positive)
                }
                .accessibilityElement(children: .combine)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func loadDay() async {
        guard let selectedDate else { return }
        transactions = nil
        error = nil
        do { transactions = try await model.reportTransactions(widgetID, date: selectedDate) }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }
}
