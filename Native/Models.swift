import Foundation

enum JSONValue: Codable, Sendable {
    case null, bool(Bool), number(Int), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

struct BudgetFile: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let cloudFileId: String?
}

struct Bootstrap: Decodable, Sendable {
    let budgets: [BudgetFile]
    let activeBudgetId: String?
}

struct BudgetListing: Decodable, Sendable { let budgets: [BudgetFile] }

struct BudgetSnapshot: Decodable, Sendable {
    let budgetName: String
    let cloudFileId: String?
    let month: String
    let currencyCode: String
    let syncWarning: String?
    let budgetType: BudgetType
    /// Envelope budgets only.
    let toBudget: Int?
    /// Tracking budgets only: projected savings for current and future months, otherwise actual savings.
    let saved: Int?
    let savedIsProjected: Bool
    let totalBudgeted: Int
    let totalSpent: Int
    let accounts: [Account]
    let groups: [CategoryGroup]
    let transactions: [Transaction]
    let payees: [Payee]

    var categories: [BudgetCategory] { groups.flatMap(\.categories) }
    var openAccounts: [Account] { accounts.filter { !$0.closed } }
}

enum BudgetType: String, Decodable, Sendable { case envelope, tracking }

struct Account: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let balance: Int
    let offbudget: Bool
    let closed: Bool
    var bankSyncEnabled: Bool? = nil
    var bankSyncStatus: String? = nil
    var lastBankSync: String? = nil

    var canSyncBank: Bool { bankSyncEnabled == true && !closed }
    var lastBankSyncDate: Date? {
        guard let lastBankSync, let milliseconds = Double(lastBankSync), milliseconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
    var bankSyncNeedsAttention: Bool {
        guard let bankSyncStatus else { return false }
        return !["ok", "pending", "sync-requested"].contains(bankSyncStatus)
    }
}

struct BankSyncResult: Decodable, Sendable {
    let accounts: [BankSyncAccountResult]
}

struct BankSyncAccountResult: Decodable, Identifiable, Sendable {
    let accountId: String
    let added: Int
    let updated: Int
    let error: String?
    var id: String { accountId }
}

struct CategoryGroup: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let categories: [BudgetCategory]
}

struct BudgetCategory: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let budgeted: Int
    let spent: Int
    let balance: Int
    let isIncome: Bool
}

struct Transaction: Decodable, Identifiable, Sendable {
    let id: String
    let accountId: String
    let date: String
    let payeeId: String?
    let payeeName: String?
    let categoryId: String?
    let categoryName: String?
    let amount: Int
    let notes: String?
    let cleared: Bool
    let isParent: Bool
    let isChild: Bool
    let isTransfer: Bool

    let reconciled: Bool?

    var canEdit: Bool { !isParent && !isChild && !isTransfer && reconciled != true }
    var title: String { payeeName.flatMap { $0.isEmpty ? nil : $0 } ?? "No payee" }
    var detail: String { categoryName ?? "Uncategorized" }
}

struct Payee: Decodable, Identifiable, Sendable { let id: String; let name: String }

struct TransactionSection: Identifiable {
    let date: String
    let transactions: [Transaction]
    var id: String { date }

    /// Filter once, then group once. Section rendering must never rescan the full register.
    static func grouped(_ transactions: [Transaction], accountID: String? = nil,
                        search: String = "", currency: String = "", locale: Locale = .current) -> [Self] {
        let formatter = search.isEmpty ? nil : Money.formatter(currency: currency, locale: locale)
        let matching = transactions.filter { transaction in
            guard !transaction.isChild, accountID == nil || transaction.accountId == accountID else { return false }
            guard let formatter else { return true }
            return transaction.title.localizedCaseInsensitiveContains(search)
                || transaction.detail.localizedCaseInsensitiveContains(search)
                || (transaction.notes ?? "").localizedCaseInsensitiveContains(search)
                || Money.formatted(transaction.amount, formatter: formatter).localizedCaseInsensitiveContains(search)
        }
        let grouped = Dictionary(grouping: matching, by: \.date)
        // Preserve the engine's ordering within each day, including its ID tie-breaker.
        return grouped.keys.sorted(by: >).map { Self(date: $0, transactions: grouped[$0] ?? []) }
    }
}

enum Money {
    static func formatted(_ minorUnits: Int, currency: String = "", locale: Locale = .current) -> String {
        formatted(minorUnits, formatter: formatter(currency: currency, locale: locale))
    }

    fileprivate static func formatter(currency: String, locale: Locale) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = currency.isEmpty ? .decimal : .currency
        if !currency.isEmpty { formatter.currencyCode = currency }
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }

    fileprivate static func formatted(_ minorUnits: Int, formatter: NumberFormatter) -> String {
        return formatter.string(from: NSDecimalNumber(decimal: Decimal(minorUnits) / 100)) ?? "—"
    }

    static func editable(_ minorUnits: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: Decimal(minorUnits) / 100)) ?? ""
    }

    /// Parse the whole localized input, without accepting fractional cents or floating-point rounding.
    static func parse(_ text: String, locale: Locale = .current) -> Int? {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.generatesDecimalNumbers = true
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        let decimalSeparator = formatter.decimalSeparator ?? "."
        let groupingSeparator = formatter.groupingSeparator ?? ","
        var normalized = input.replacingOccurrences(of: groupingSeparator, with: "")
        normalized = normalized.replacingOccurrences(of: decimalSeparator, with: ".")
        normalized = normalized.replacingOccurrences(of: formatter.minusSign ?? "-", with: "-")
        normalized = normalized.map { character in
            character.wholeNumberValue.map(String.init) ?? String(character)
        }.joined()
        guard normalized.range(of: "^[+-]?[0-9]+(?:\\.[0-9]{1,2})?$", options: .regularExpression) != nil,
              formatter.number(from: input) != nil,
              let decimal = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let cents = decimal * 100
        // Actual stores exact JS integers; stay within that range at the bridge boundary.
        guard cents >= -9_007_199_254_740_991, cents <= 9_007_199_254_740_991 else { return nil }
        return NSDecimalNumber(decimal: cents).intValue
    }
}

enum BudgetDate {
    static func month(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static func date(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }
}
