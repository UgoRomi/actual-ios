import Foundation

/// A schedule, as Actual's schedules pages list it.
struct Schedule: Decodable, Identifiable, Sendable {
    enum Status: String, Decodable, Sendable { case completed, paid, due, upcoming, missed, scheduled }
    /// How a transaction's amount matches, as Actual's schedule editor offers.
    enum AmountOp: String, Decodable, Sendable, CaseIterable { case `is`, isapprox, isbetween }

    let id: String
    let name: String?
    let payeeId: String?
    let accountId: String?
    let amount: ScheduleAmount
    let amountOp: AmountOp
    let date: ScheduleDate
    let nextDate: String?
    let completed: Bool
    let postsTransaction: Bool
    let status: Status
}

/// Transactions linked to a schedule, and unlinked ones its conditions match.
struct ScheduleTransactions: Decodable, Sendable {
    struct Item: Decodable, Identifiable, Sendable {
        let id: String
        let date: String
        let amount: Int
        let accountId: String?
        let payeeId: String?
        let notes: String
    }
    let linked: [Item]
    let matching: [Item]
}

/// An upcoming transaction from a schedule, shown before the saved ones as Actual's registers do.
struct ScheduledTransaction: Decodable, Identifiable, Sendable {
    let id: String
    let scheduleId: String
    let scheduleName: String?
    let accountId: String?
    let date: String
    let amount: Int
    let payeeName: String?
    let categoryName: String?
    let isTransfer: Bool
    let status: Schedule.Status
    /// A date after the schedule's next one, which is upcoming whatever the schedule's status.
    let forceUpcoming: Bool
    /// Repeating schedules can skip a date; one-time schedules can be completed instead.
    let recurring: Bool

    var shownStatus: Schedule.Status { forceUpcoming ? .upcoming : status }
    var title: String { payeeName.flatMap { $0.isEmpty ? nil : $0 } ?? scheduleName ?? "Scheduled transaction" }
}

enum ScheduleAmount: Decodable, Sendable, Equatable {
    case exact(Int)
    case range(Int, Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) { self = .exact(value); return }
        struct Range: Decodable { let num1: Int; let num2: Int }
        let range = try container.decode(Range.self)
        self = .range(range.num1, range.num2)
    }

    /// What a posted transaction gets: for a range, its midpoint, as Actual's getScheduledAmount.
    var scheduled: Int {
        switch self {
        case .exact(let value): value
        case .range(let low, let high): Int((Double(low + high) / 2).rounded())
        }
    }

    var json: JSONValue {
        switch self {
        case .exact(let value): .number(value)
        case .range(let low, let high): .object(["num1": .number(low), "num2": .number(high)])
        }
    }
}

/// A schedule's date: one day, or a repeating date as Actual's RecurConfig stores it.
enum ScheduleDate: Decodable, Sendable, Equatable {
    case once(String)
    case recurring(Recurrence)

    struct Recurrence: Decodable, Sendable, Equatable {
        enum Frequency: String, Decodable, Sendable, CaseIterable { case daily, weekly, monthly, yearly }
        enum EndMode: String, Decodable, Sendable, CaseIterable {
            case never, afterOccurrences = "after_n_occurrences", onDate = "on_date"
        }
        enum WeekendMode: String, Decodable, Sendable, CaseIterable { case before, after }

        var start: String
        var frequency: Frequency
        var interval = 1
        /// Patterns set in Actual, such as "the last Friday", kept as they are.
        var patterns: [JSONValue] = []
        var skipWeekend = false
        var weekendSolveMode = WeekendMode.after
        var endMode = EndMode.never
        var endOccurrences = 1
        var endDate: String? = nil

        /// A specific day of a monthly schedule: a day of the month, or the nth weekday; -1 is the last.
        struct Pattern: Hashable, Sendable {
            /// "day", or a weekday such as "FR".
            var type: String
            var value: Int

            static let weekdays = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        }

        /// Actual's patterns as specific days; setting them replaces the patterns.
        var specificDays: [Pattern] {
            get {
                patterns.compactMap { pattern in
                    guard case .object(let fields) = pattern, case .string(let type) = fields["type"],
                          case .number(let value) = fields["value"] else { return nil }
                    return Pattern(type: type, value: value)
                }
            }
            set {
                patterns = newValue.map { .object(["type": .string($0.type), "value": .number($0.value)]) }
            }
        }

        init(start: String, frequency: Frequency) {
            self.start = start
            self.frequency = frequency
        }

        enum CodingKeys: String, CodingKey {
            case start, frequency, interval, patterns, skipWeekend, weekendSolveMode, endMode, endOccurrences, endDate
        }

        // Actual leaves out settings that are at their defaults.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            start = try container.decode(String.self, forKey: .start)
            frequency = try container.decode(Frequency.self, forKey: .frequency)
            interval = try container.decodeIfPresent(Int.self, forKey: .interval) ?? 1
            patterns = try container.decodeIfPresent([JSONValue].self, forKey: .patterns) ?? []
            skipWeekend = try container.decodeIfPresent(Bool.self, forKey: .skipWeekend) ?? false
            weekendSolveMode = try container.decodeIfPresent(WeekendMode.self, forKey: .weekendSolveMode) ?? .after
            endMode = try container.decodeIfPresent(EndMode.self, forKey: .endMode) ?? .never
            endOccurrences = try container.decodeIfPresent(Int.self, forKey: .endOccurrences) ?? 1
            endDate = try container.decodeIfPresent(String.self, forKey: .endDate)
        }

        var json: JSONValue {
            var fields: [String: JSONValue] = [
                "start": .string(start), "frequency": .string(frequency.rawValue), "interval": .number(interval),
                "patterns": .array(patterns), "skipWeekend": .bool(skipWeekend),
                "weekendSolveMode": .string(weekendSolveMode.rawValue), "endMode": .string(endMode.rawValue),
                "endOccurrences": .number(endOccurrences),
            ]
            if let endDate { fields["endDate"] = .string(endDate) }
            return .object(fields)
        }

        /// A short description, such as "Every 2 weeks" or "Monthly, 3 times".
        var summary: String {
            let unit: String = switch frequency {
            case .daily: "day"
            case .weekly: "week"
            case .monthly: "month"
            case .yearly: "year"
            }
            var text = interval == 1 ? frequency.rawValue.capitalized : "Every \(interval) \(unit)s"
            switch endMode {
            case .never: break
            case .afterOccurrences: text += endOccurrences == 1 ? ", once" : ", \(endOccurrences) times"
            case .onDate: if let endDate { text += ", until \(endDate)" }
            }
            if !specificDays.isEmpty { text += ", on specific days" }
            return text
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let day = try? container.decode(String.self) { self = .once(day) }
        else { self = .recurring(try container.decode(Recurrence.self)) }
    }

    var json: JSONValue {
        switch self {
        case .once(let day): .string(day)
        case .recurring(let recurrence): recurrence.json
        }
    }
}
