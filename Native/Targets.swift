import Foundation

/// A category's targets, which Actual calls budget automations or goal templates.
struct CategoryTargets: Decodable, Sendable {
    enum Source: String, Decodable, Sendable {
        /// `#template` and `#goal` lines in the category's notes. Saving moves them to the editor, as in Actual.
        case notes
        case ui
    }
    let source: Source
    /// The notes lines that saving replaces.
    let noteLines: [String]
    /// Notes lines Actual could not read. Fix them in Actual first.
    let unsupported: [String]
    let templates: [TargetTemplate]
    let schedules: [TargetSchedule]
    let incomeCategories: [IncomeCategory]
    let preview: TargetPreview?
}

struct TargetSchedule: Decodable, Sendable, Identifiable, Hashable { let id: String; let name: String }
struct IncomeCategory: Decodable, Sendable, Identifiable, Hashable { let id: String; let name: String }

/// What targets would budget this month, and what must be fixed before saving.
struct TargetPreview: Decodable, Sendable, Equatable {
    let budgeted: Int
    /// Each template's contribution, in order.
    let perTemplate: [Int]
    /// Each template's problem, in order.
    let problems: [String?]
    let conflicts: [String]

    var canSave: Bool { problems.allSatisfy { $0 == nil } && conflicts.isEmpty }
}

struct TargetsApplied: Decodable, Sendable { let message: String }

extension JSONValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}

/// One target, kept in Actual's template format so fields round-trip unchanged.
/// Amounts are integer minor units; the bridge converts Actual's decimal amounts.
struct TargetTemplate: Decodable, Identifiable, Sendable, Equatable {
    /// The kinds the web editor offers, each of which may cover several template types.
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case fixed, schedule, by, percentage, historical, limit, refill, remainder, goal
        var id: Self { self }

        /// Kinds that contribute funds each month. Balance caps and goals are options.
        static let automations: [Kind] = [.fixed, .schedule, .by, .percentage, .historical, .refill, .remainder]
        /// Actual allows one of each of these per category.
        var isSingleton: Bool { [.limit, .refill, .remainder, .goal].contains(self) }

        var title: String {
            switch self {
            case .fixed: "Fixed amount"
            case .schedule: "Cover schedule"
            case .by: "Save by date"
            case .percentage: "% of income"
            case .historical: "From history"
            case .limit: "Balance cap"
            case .refill: "Refill to cap"
            case .remainder: "Whatever is left"
            case .goal: "Long-term goal"
            }
        }
        var detail: String {
            switch self {
            case .fixed: "Add a set amount every month, week, day, or year."
            case .schedule: "Save up for a scheduled transaction."
            case .by: "Spread a target amount across the months until a deadline."
            case .percentage: "A share of this month's or last month's income."
            case .historical: "Use past months: average, a specific month, or a copy."
            case .limit: "Stop budgeting to this category once the balance reaches a cap."
            case .refill: "Top the category back up to the balance cap each month."
            case .remainder: "Split any remaining money to budget across these categories."
            case .goal: "A long-term savings target. The balance is colored by progress toward it, instead of this month's funding."
            }
        }
        var systemImage: String {
            switch self {
            case .fixed: "banknote"
            case .schedule: "calendar"
            case .by: "flag.checkered"
            case .percentage: "chart.pie"
            case .historical: "clock.arrow.circlepath"
            case .limit: "equal.circle"
            case .refill: "arrow.triangle.2.circlepath"
            case .remainder: "square.split.2x1"
            case .goal: "flag"
            }
        }
    }

    let id: UUID
    private(set) var fields: [String: JSONValue]

    init(fields: [String: JSONValue]) {
        id = UUID()
        self.fields = fields
    }

    init(from decoder: Decoder) throws {
        self.init(fields: try decoder.singleValueContainer().decode([String: JSONValue].self))
    }

    /// Actual's editor defaults. Amounts assume two decimal places, as this app does.
    init(kind: Kind, today: Date = Date()) {
        let month = BudgetDate.month(today)
        let firstDay = month + "-01"
        let fields: [String: JSONValue] = switch kind {
        case .fixed: [
            "type": "periodic", "amount": .number(10_000), "starting": .string(firstDay),
            "period": .object(["period": "month", "amount": .number(1)]),
        ]
        case .schedule: ["type": "schedule", "name": ""]
        case .by: [
            "type": "by", "amount": .number(120_000), "month": .string(Self.month(month, adding: 12)),
            "annual": .bool(true), "repeat": .number(1),
        ]
        case .percentage: ["type": "percentage", "percent": .number(15), "previous": .bool(false), "category": "all income"]
        case .historical: ["type": "average", "numMonths": .number(3)]
        case .limit: ["type": "limit", "amount": .number(50_000), "period": "monthly", "hold": .bool(false), "priority": .null]
        case .refill: ["type": "refill"]
        case .remainder: ["type": "remainder", "weight": .number(1), "priority": .null]
        case .goal: ["type": "goal", "directive": "goal", "amount": .number(100_000)]
        }
        var result = fields
        if kind != .goal { result["directive"] = "template" }
        if result["priority"] == nil, kind != .goal { result["priority"] = .number(1) }
        self.init(fields: result)
    }

    var json: JSONValue { .object(fields) }

    var type: String { string("type") ?? "" }
    var kind: Kind? {
        switch type {
        case "periodic", "simple": .fixed
        case "schedule": .schedule
        case "by", "spend": .by
        case "percentage": .percentage
        case "average", "copy": .historical
        case "limit": .limit
        case "refill": .refill
        case "remainder": .remainder
        case "goal": .goal
        default: nil
        }
    }

    /// Switches kind, keeping the note, like Actual's editor.
    mutating func change(to kind: Kind) {
        guard kind != self.kind else { return }
        let description = fields["description"]
        fields = TargetTemplate(kind: kind).fields
        fields["description"] = description
    }

    // MARK: Fields

    func string(_ key: String) -> String? { if case .string(let value) = fields[key] { value } else { nil } }
    func int(_ key: String) -> Int? {
        switch fields[key] {
        case .number(let value): value
        case .double(let value): Int(exactly: value.rounded())
        default: nil
        }
    }
    func double(_ key: String) -> Double? {
        switch fields[key] {
        case .number(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }
    func bool(_ key: String) -> Bool { if case .bool(true) = fields[key] { true } else { false } }
    func has(_ key: String) -> Bool { fields[key].map { $0 != .null } ?? false }
    mutating func set(_ key: String, _ value: JSONValue?) { fields[key] = value }

    var amount: Int {
        get { int("amount") ?? 0 }
        set { fields["amount"] = .number(newValue) }
    }
    /// Contribution order. Balance caps, goals, and whatever-is-left have none.
    var priority: Int? {
        get { int("priority") }
        set { fields["priority"] = newValue.map(JSONValue.number) ?? .null }
    }
    var note: String {
        get { string("description") ?? "" }
        set { fields["description"] = newValue.isEmpty ? nil : .string(newValue) }
    }
    /// Periodic templates: the unit and count, such as every 2 weeks.
    var periodUnit: String {
        get { if case .object(let period) = fields["period"], case .string(let unit) = period["period"] { unit } else { "month" } }
        set { fields["period"] = .object(["period": .string(newValue), "amount": .number(periodCount)]) }
    }
    var periodCount: Int {
        get { if case .object(let period) = fields["period"], case .number(let count) = period["amount"] { count } else { 1 } }
        set { fields["period"] = .object(["period": .string(periodUnit), "amount": .number(newValue)]) }
    }
    /// Save by date: repeating targets have an interval in months, or in years when annual.
    var repeats: Bool {
        get { has("annual") || has("repeat") }
        set {
            fields["annual"] = newValue ? .bool(false) : nil
            fields["repeat"] = newValue ? .number(int("repeat") ?? 1) : nil
        }
    }
    /// Save by date: the spend template lets money be spent before the target month.
    var allowsEarlySpending: Bool {
        get { type == "spend" }
        set {
            fields["type"] = newValue ? "spend" : "by"
            fields["from"] = newValue ? .string(string("from") ?? string("month") ?? BudgetDate.month(Date())) : nil
        }
    }
    enum Adjustment: String, CaseIterable, Identifiable { case none, percent, fixed; var id: Self { self } }
    /// Schedule and average templates may be increased or decreased.
    var adjustmentKind: Adjustment {
        get { Adjustment(rawValue: string("adjustmentType") ?? "") ?? .none }
        set {
            switch newValue {
            case .none: fields["adjustmentType"] = nil; fields["adjustment"] = nil
            case .percent: fields["adjustmentType"] = "percent"; fields["adjustment"] = .number(10)
            case .fixed: fields["adjustmentType"] = "fixed"; fields["adjustment"] = .number(1_000)
            }
        }
    }

    // MARK: Summary

    /// The sentence Actual's editor shows for a target.
    func summary(currency: String, income: [IncomeCategory] = []) -> String {
        let money = { (value: Int) in Money.formatted(value, currency: currency) }
        func every(_ count: Int, _ unit: String) -> String { count == 1 ? "every \(unit)" : "every \(count) \(unit)s" }
        switch type {
        case "periodic":
            return "Budget \(money(amount)) \(every(periodCount, periodUnit))"
        case "schedule":
            let name = string("name") ?? ""
            guard !name.isEmpty else { return "Budget for a schedule" }
            let base = bool("full") ? "Cover the occurrences of the schedule ‘\(name)’ this month" : "Save up for the schedule ‘\(name)’"
            return base + adjustmentSummary(money)
        case "by", "spend":
            var text = "Save \(money(amount)) by \(Self.monthLabel(string("month") ?? ""))"
            if type == "spend" { text += ", early spending from \(Self.monthLabel(string("from") ?? ""))" }
            let count = int("repeat") ?? 1
            if bool("annual") { text += ", repeating \(every(count, "year"))" }
            else if let count = int("repeat"), count > 0 { text += ", repeating \(every(count, "month"))" }
            return text
        case "percentage":
            let percent = (double("percent") ?? 0).formatted()
            let when = bool("previous") ? "last month" : "this month"
            switch string("category") ?? "" {
            case "all income": return "Budget \(percent)% of total income \(when)"
            case "available funds": return "Budget \(percent)% of available funds to budget \(when)"
            case let source:
                let name = income.first { $0.id == source }?.name ?? source
                return "Budget \(percent)% of ‘\(name)’ \(when)"
            }
        case "copy":
            return "Budget the same amount as \(int("lookBack") ?? 1) months ago"
        case "average":
            return "Budget the average of the last \(int("numMonths") ?? 1) complete months" + adjustmentSummary(money)
        case "limit":
            let unit = switch string("period") { case "daily": "day"; case "weekly": "week"; default: "month" }
            return "Set a balance limit of \(money(amount))/\(unit) (\(bool("hold") ? "soft cap" : "hard cap"))"
        case "refill":
            return "Refill to balance limit"
        case "remainder":
            return "Share remaining funds to budget (weight \(int("weight") ?? 1))"
        case "goal":
            return "Long-term goal of \(money(amount))"
        default:
            return "Unsupported template type: \(type)"
        }
    }

    private func adjustmentSummary(_ money: (Int) -> String) -> String {
        guard let value = double("adjustment"), value != 0 else { return "" }
        let direction = value > 0 ? "increased" : "decreased"
        switch adjustmentKind {
        case .percent: return " (\(direction) by \(abs(value).formatted())%)"
        case .fixed: return " (\(direction) by \(money(abs(int("adjustment") ?? 0))))"
        case .none: return ""
        }
    }

    // MARK: Months

    static func month(_ month: String, adding offset: Int) -> String {
        guard let date = BudgetDate.date(month + "-01"),
              let moved = Calendar(identifier: .gregorian).date(byAdding: .month, value: offset, to: date) else { return month }
        return BudgetDate.month(moved)
    }

    /// Formats `yyyy-MM` like Actual's editor, such as Sep 2027.
    static func monthLabel(_ month: String) -> String {
        guard let date = BudgetDate.date(month + "-01") else { return "—" }
        return date.formatted(.dateTime.month(.abbreviated).year())
    }
}
