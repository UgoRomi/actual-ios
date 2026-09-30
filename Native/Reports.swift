import Foundation

/// The budget's report dashboards, as Actual's mobile web app shows them.
struct ReportsDashboard: Decodable, Sendable, Equatable {
    /// Where "All time" starts: the month of the earliest transaction.
    let earliestMonth: String
    let pages: [DashboardPage]
}

struct DashboardPage: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    /// Top to bottom, then left to right.
    let widgets: [ReportWidget]
}

struct ReportWidget: Decodable, Sendable, Identifiable, Hashable {
    enum Kind: Sendable { case netWorth, cashFlow, spending, summary, calendar, markdown, other }

    let id: String
    let type: String
    /// The widget's own name, or the custom report's.
    let name: String?
    /// Text widgets only: their Markdown.
    let content: String?
    let textAlign: String?

    var kind: Kind {
        switch type {
        case "net-worth-card": .netWorth
        case "cash-flow-card": .cashFlow
        case "spending-card": .spending
        case "summary-card": .summary
        case "calendar-card": .calendar
        case "markdown-card": .markdown
        default: .other
        }
    }

    /// Widgets whose saved settings this app edits.
    var isEditable: Bool { kind != .other }

    var title: String {
        if let name, !name.isEmpty { return name }
        return Self.defaultTitle(type)
    }

    /// Actual's default names.
    static func defaultTitle(_ type: String) -> String {
        switch type {
        case "net-worth-card": "Net Worth"
        case "cash-flow-card": "Cash Flow"
        case "spending-card": "Monthly Spending"
        case "summary-card": "Summary"
        case "calendar-card": "Calendar"
        case "custom-report": "Custom Report"
        case "age-of-money-card": "Age of Money"
        case "crossover-card": "Crossover Point"
        case "budget-analysis-card": "Budget Analysis"
        case "balance-forecast-card": "Balance Forecast"
        case "monte-carlo-card": "Monte Carlo Analysis"
        case "formula-card": "Formula"
        case "sankey-card": "Sankey"
        default: "Report"
        }
    }
}

/// A saved or chosen range, evaluated by the engine as Actual's `calculateTimeRange` does.
struct ReportTimeFrame: Hashable, Sendable, Decodable {
    var start: String
    var end: String
    var mode: String

    var json: JSONValue { .object(["start": .string(start), "end": .string(end), "mode": .string(mode)]) }

    /// Months rather than days at both ends.
    var isMonthly: Bool { start.count == 7 && end.count == 7 }

    /// The quick-select preset that saves this range, if one does.
    func preset(earliestMonth: String, oneMonth: Bool, today: Date = Date()) -> ReportRangePreset? {
        ReportRangePreset.available(oneMonth: oneMonth).first { preset in
            let frame = preset.timeFrame(earliestMonth: earliestMonth, today: today)
            switch frame.mode {
            case "sliding-window": return frame == self
            // All time keeps its first month; only the mode says where it ends.
            case "full": return mode == "full" && String(start.prefix(7)) == frame.start
            default: return frame.mode == mode
            }
        }
    }
}

/// Actual's quick-select date ranges for reports (dateRangePresets.ts).
enum ReportRangePreset: String, CaseIterable, Identifiable, Sendable {
    case oneMonth, threeMonths, sixMonths, oneYear, yearToDate, lastMonth, lastYear, priorYearToDate
    case currentQuarter, previousQuarter, allTime

    var id: String { rawValue }
    var title: String {
        switch self {
        case .oneMonth: "1 month"
        case .threeMonths: "3 months"
        case .sixMonths: "6 months"
        case .oneYear: "1 year"
        case .yearToDate: "Year to date"
        case .lastMonth: "Last month"
        case .lastYear: "Last year"
        case .priorYearToDate: "Prior year to date"
        case .currentQuarter: "Current quarter"
        case .previousQuarter: "Previous quarter"
        case .allTime: "All time"
        }
    }

    /// Cash flow, summary, and calendar also offer a single month, as in Actual.
    static func available(oneMonth: Bool) -> [Self] { allCases.filter { oneMonth || $0 != .oneMonth } }

    func timeFrame(earliestMonth: String, today: Date = Date()) -> ReportTimeFrame {
        let current = BudgetDate.month(today)
        func live(_ months: Int) -> ReportTimeFrame {
            let start = Calendar(identifier: .gregorian).date(byAdding: .month, value: -months, to: today) ?? today
            return ReportTimeFrame(start: BudgetDate.month(start), end: current, mode: "sliding-window")
        }
        func mode(_ mode: String) -> ReportTimeFrame { ReportTimeFrame(start: current, end: current, mode: mode) }
        return switch self {
        case .oneMonth: live(0)
        case .threeMonths: live(2)
        case .sixMonths: live(5)
        case .oneYear: live(11)
        case .yearToDate: mode("yearToDate")
        case .lastMonth: mode("lastMonth")
        case .lastYear: mode("lastYear")
        case .priorYearToDate: mode("priorYearToDate")
        case .currentQuarter: mode("currentQuarter")
        case .previousQuarter: mode("previousQuarter")
        case .allTime: ReportTimeFrame(start: min(earliestMonth, current), end: current, mode: "full")
        }
    }
}

/// One widget's data. Exactly one report is present, matching `type`.
struct ReportData: Decodable, Sendable {
    let type: String
    var netWorth: NetWorthReport? = nil
    var cashFlow: CashFlowReport? = nil
    var spending: SpendingReport? = nil
    var summary: SummaryReport? = nil
    var calendar: CalendarReport? = nil
}

struct NetWorthReport: Decodable, Sendable {
    struct Point: Decodable, Sendable, Identifiable {
        /// An ISO day, week start, month, or year, by interval.
        let date: String
        let total: Int
        let assets: Int
        let debt: Int
        let balances: [String: Int]
        var id: String { date }
    }
    struct AccountName: Decodable, Sendable, Identifiable { let id: String; let name: String }
    let start: String
    let end: String
    /// Daily, Weekly, Monthly, or Yearly.
    let interval: String
    /// "trend" or "stacked".
    let mode: String
    let netWorth: Int
    let totalChange: Int
    let points: [Point]
    /// Accounts with a balance in the range.
    let accounts: [AccountName]
}

struct CashFlowReport: Decodable, Sendable {
    struct Point: Decodable, Sendable, Identifiable {
        /// A day, or a month for ranges over three months.
        let date: String
        let income: Int
        let expense: Int
        let transfers: Int
        let balance: Int
        var id: String { date }
    }
    struct Detail: Decodable, Sendable {
        let isConcise: Bool
        let points: [Point]
        let balance: Int
        let totalIncome: Int
        let totalExpenses: Int
        let totalTransfers: Int
        let totalChange: Int
    }
    let start: String
    let end: String
    let showBalance: Bool
    /// On-budget income and expenses, excluding transfers, through today.
    let income: Int
    let expense: Int
    let detail: Detail?
}

struct SpendingReport: Decodable, Sendable {
    enum Mode: String, Decodable, Sendable, CaseIterable, Identifiable {
        case singleMonth = "single-month", budget, average
        var id: String { rawValue }
        var title: String {
            switch self {
            case .singleMonth: "Single month"
            case .budget: "Budgeted"
            case .average: "Average"
            }
        }
    }
    struct AverageRange: Decodable, Sendable, Hashable {
        var mode: String
        var months: Int? = nil

        /// spendingAverageRange.ts options.
        static let options = [
            AverageRange(mode: "last-n-months", months: 3), AverageRange(mode: "last-n-months", months: 6),
            AverageRange(mode: "last-n-months", months: 12), AverageRange(mode: "year-to-date"), AverageRange(mode: "all-time"),
        ]
        var json: JSONValue {
            var fields: [String: JSONValue] = ["mode": .string(mode)]
            if mode == "last-n-months" { fields["months"] = .number(months ?? 3) }
            return .object(fields)
        }
        /// spendingAverageRange.ts labels.
        var title: String {
            switch mode {
            case "year-to-date": "YTD"
            case "all-time": "All time"
            default: "Last \(months ?? 3) months"
            }
        }
    }
    /// Cumulative spending through each day of the month; days 28 and later count as the 28th.
    struct Day: Decodable, Sendable, Identifiable {
        let day: Int
        /// Nil after today.
        let compare: Int?
        let compareTo: Int?
        let budget: Int
        let average: Int
        var id: Int { day }

        func value(_ mode: Mode) -> Int? {
            switch mode {
            case .singleMonth: compareTo
            case .budget: budget
            case .average: average
            }
        }
    }
    let compare: String
    let compareTo: String
    let mode: Mode
    let averageRange: AverageRange
    let todayIndex: Int
    let days: [Day]

    /// SpendingCard's difference to date: more spent than the comparison is positive.
    func difference(_ mode: Mode) -> Int? {
        guard days.indices.contains(todayIndex) else { return nil }
        let day = days[todayIndex]
        return (day.value(mode) ?? 0) - (day.compare ?? 0)
    }
}

struct SummaryReport: Decodable, Sendable {
    let start: String
    let end: String
    /// sum, avgPerMonth, avgPerYear, avgPerTransact, or percentage.
    let type: String
    /// Minor units, or a percentage. Nil when a percentage divides by zero.
    let total: Double?
    let dividend: Int
    /// A count of months, years, or transactions, or the percentage's base amount.
    let divisor: Double
    let divisorAllTime: Bool
}

struct CalendarReport: Decodable, Sendable {
    struct Day: Decodable, Sendable, Identifiable {
        let date: String
        let income: Int
        /// Positive: the day's spending.
        let expense: Int
        var id: String { date }
    }
    struct Month: Decodable, Sendable, Identifiable {
        let month: String
        let totalIncome: Int
        let totalExpense: Int
        /// Only days with transactions.
        let days: [Day]
        var id: String { month }
    }
    let start: String
    let end: String
    /// 0 is Sunday, as in Actual's preference.
    let firstDayOfWeekIdx: Int
    let months: [Month]
}

struct ReportTransaction: Decodable, Sendable, Identifiable {
    let id: String
    let date: String
    let amount: Int
    let accountName: String
    let payeeName: String?
    let categoryName: String?
    let notes: String
}

/// Report dates, formatted for display.
enum ReportDate {
    private static let calendar = Calendar(identifier: .gregorian)

    /// An ISO day, month, or year, at the start of that period in the current time zone.
    static func date(_ value: String) -> Date? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        let numbers = parts.compactMap { $0 }
        return calendar.date(from: DateComponents(
            year: numbers[0], month: numbers.count > 1 ? numbers[1] : 1, day: numbers.count > 2 ? numbers[2] : 1))
    }

    static func month(_ value: String, style: Date.FormatStyle.Symbol.Month = .abbreviated) -> String {
        guard let date = date(value) else { return value }
        return date.formatted(.dateTime.month(style).year())
    }

    /// DateRange.tsx: one month, or first and last months.
    static func range(_ start: String, _ end: String) -> String {
        let first = month(start), last = month(end)
        return first == last ? month(end, style: .wide) : "\(first) – \(last)"
    }

    /// A `yyyy-MM` month moved by whole months.
    static func month(_ month: String, adding offset: Int) -> String {
        guard let start = date(String(month.prefix(7))),
              let moved = calendar.date(byAdding: .month, value: offset, to: start) else { return month }
        return BudgetDate.month(moved)
    }

    /// Whole months from one month or day to another's month.
    static func months(from start: String, to end: String) -> Int {
        guard let first = date(String(start.prefix(7))), let last = date(String(end.prefix(7))) else { return 0 }
        return calendar.dateComponents([.month], from: first, to: last).month ?? 0
    }

    /// Every month from one to another, newest first.
    static func months(between first: String, and last: String) -> [String] {
        let count = months(from: first, to: last)
        guard count >= 0 else { return [last] }
        return (0...count).map { month(last, adding: -$0) }
    }

    /// A saved range that no preset describes, in words.
    static func describe(_ frame: ReportTimeFrame) -> String {
        func label(_ value: String) -> String {
            guard value.count == 10, let day = date(value) else { return month(value) }
            return day.formatted(date: .abbreviated, time: .omitted)
        }
        switch frame.mode {
        case "full": return "Since \(month(frame.start, style: .wide))"
        case "sliding-window":
            // Day ranges keep their length and end today.
            if !frame.isMonthly, let first = date(frame.start), let last = date(frame.end),
               let days = calendar.dateComponents([.day], from: first, to: last).day {
                return days == 0 ? "Today" : "Last \(days + 1) days"
            }
            return "\(label(frame.start)) – \(label(frame.end))"
        default: return "\(label(frame.start)) – \(label(frame.end))"
        }
    }
}

/// The editor's range: one of Actual's presets, the last so many months, fixed months,
/// or the range as saved when none of those describes it.
struct ReportRangeDraft: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case saved, preset(ReportRangePreset), live, fixed }

    var kind: Kind
    /// For `live`: how many months, ending with the current one.
    var liveMonths: Int
    /// For `fixed`: the first and last months.
    var start: String
    var end: String

    /// From a widget's range as the engine evaluated it today.
    init(_ frame: ReportTimeFrame, earliestMonth: String, oneMonth: Bool, today: Date = Date()) {
        let first = String(frame.start.prefix(7)), last = String(frame.end.prefix(7))
        start = min(first, last)
        end = max(first, last)
        liveMonths = min(max(ReportDate.months(from: start, to: end) + 1, 1), 120)
        if let preset = frame.preset(earliestMonth: earliestMonth, oneMonth: oneMonth, today: today) {
            kind = .preset(preset)
        } else if frame.isMonthly, first <= last, frame.mode == "sliding-window" {
            kind = .live
        } else if frame.isMonthly, first <= last, frame.mode == "static" {
            kind = .fixed
        } else {
            kind = .saved
        }
    }

    /// The range to save, or nil to keep the saved one.
    func timeFrame(earliestMonth: String, today: Date = Date()) -> ReportTimeFrame? {
        let current = BudgetDate.month(today)
        switch kind {
        case .saved: return nil
        case .preset(let preset): return preset.timeFrame(earliestMonth: earliestMonth, today: today)
        case .live:
            return ReportTimeFrame(start: ReportDate.month(current, adding: 1 - liveMonths), end: current, mode: "sliding-window")
        case .fixed: return ReportTimeFrame(start: min(start, end), end: max(start, end), mode: "static")
        }
    }
}

/// A widget's saved settings with Actual's defaults filled in, as the editor opens with them.
/// Each kind of widget has only its own settings.
struct ReportWidgetSettings: Decodable, Sendable, Equatable {
    let id: String
    let type: String
    var name: String
    /// Filters, as Actual's filter menu saves them.
    var conditions: [RuleItem]
    var conditionsOp: String
    /// Evaluated today: a live range ends this month.
    var timeFrame: ReportTimeFrame? = nil
    // Net worth
    var interval: String? = nil
    var graphMode: String? = nil
    // Cash flow
    var showBalance: Bool? = nil
    // Spending. Without a month, the current month; without one to compare with, the month before.
    var compare: String? = nil
    var compareTo: String? = nil
    var spendingMode: SpendingReport.Mode? = nil
    var averageRange: SpendingReport.AverageRange? = nil
    // Summary
    var summaryType: String? = nil
    var divisorConditions: [RuleItem]? = nil
    var divisorConditionsOp: String? = nil
    var divisorAllTimeDateRange: Bool? = nil
    // Text
    var content: String? = nil
    var textAlign: String? = nil

    /// Summary.tsx's choices.
    static let summaryTypes: [(id: String, title: String)] = [
        ("sum", "Sum"), ("avgPerMonth", "Average per month"), ("avgPerYear", "Average per year"),
        ("avgPerTransact", "Average per transaction"), ("percentage", "Percentage"),
    ]

    /// Only what differs from the saved settings, so saving leaves everything else as it is.
    /// `timeFrame` is a newly chosen range, if any.
    func changes(from saved: ReportWidgetSettings, timeFrame: ReportTimeFrame? = nil) -> [String: JSONValue] {
        var changes: [String: JSONValue] = [:]
        func filters(_ items: [RuleItem]) -> JSONValue { .array(items.map { .object($0.raw) }) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != saved.name { changes["name"] = .string(trimmed) }
        if conditions != saved.conditions { changes["conditions"] = filters(conditions) }
        if conditionsOp != saved.conditionsOp { changes["conditionsOp"] = .string(conditionsOp) }
        if let timeFrame { changes["timeFrame"] = timeFrame.json }
        if let interval, interval != saved.interval { changes["interval"] = .string(interval) }
        if let graphMode, graphMode != saved.graphMode { changes["graphMode"] = .string(graphMode) }
        if let showBalance, showBalance != saved.showBalance { changes["showBalance"] = .bool(showBalance) }
        if compare != saved.compare { changes["compare"] = compare.map { .string($0) } ?? .null }
        if compareTo != saved.compareTo { changes["compareTo"] = compareTo.map { .string($0) } ?? .null }
        if let spendingMode, spendingMode != saved.spendingMode { changes["spendingMode"] = .string(spendingMode.rawValue) }
        if let averageRange, averageRange != saved.averageRange { changes["averageRange"] = averageRange.json }
        if let summaryType, summaryType != saved.summaryType { changes["summaryType"] = .string(summaryType) }
        if let divisorConditions, divisorConditions != saved.divisorConditions {
            changes["divisorConditions"] = filters(divisorConditions)
        }
        if let divisorConditionsOp, divisorConditionsOp != saved.divisorConditionsOp {
            changes["divisorConditionsOp"] = .string(divisorConditionsOp)
        }
        if let divisorAllTimeDateRange, divisorAllTimeDateRange != saved.divisorAllTimeDateRange {
            changes["divisorAllTimeDateRange"] = .bool(divisorAllTimeDateRange)
        }
        if let content, content != saved.content { changes["content"] = .string(content) }
        if let textAlign, textAlign != saved.textAlign { changes["textAlign"] = .string(textAlign) }
        return changes
    }
}
