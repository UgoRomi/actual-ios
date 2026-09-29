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
            if !patterns.isEmpty { text += ", with a custom pattern" }
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
