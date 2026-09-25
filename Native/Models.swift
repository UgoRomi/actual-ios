import Foundation
import Synchronization

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

/// The open budget's metadata, accounts with balances, and payees.
struct BudgetOverview: Decodable, Sendable {
    let budgetName: String
    let cloudFileId: String?
    let currencyCode: String
    let syncWarning: SyncWarning?
    let accounts: [Account]
    let payees: [Payee]

    var openAccounts: [Account] { accounts.filter { !$0.closed } }
}

struct SyncWarning: Decodable, Sendable {
    enum Kind: String, Decodable, Sendable {
        /// Another device's changes were discarded. The user may continue, as in Actual.
        case dropped
        /// Changes from a newer Actual version wait for an app update.
        case newerVersion = "newer-version"
    }
    let kind: Kind
    let message: String
}

/// One month of the budget.
struct BudgetMonth: Decodable, Sendable {
    let month: String
    let budgetType: BudgetType
    /// Envelope budgets only.
    let toBudget: Int?
    /// Tracking budgets only: projected savings for current and future months, otherwise actual savings.
    let saved: Int?
    let savedIsProjected: Bool
    let totalBudgeted: Int
    let totalSpent: Int
    let groups: [CategoryGroup]

    var categories: [BudgetCategory] { groups.flatMap(\.categories) }
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
    var clearedBalance: Int? = nil
    /// The latest balance reported by a linked bank.
    var bankBalance: Int? = nil
    var lastReconciled: String? = nil

    var canSyncBank: Bool { bankSyncEnabled == true && !closed }
    var lastBankSyncDate: Date? { Self.date(lastBankSync) }
    var lastReconciledDate: Date? { Self.date(lastReconciled) }
    /// Actual stores these times as milliseconds in a string.
    private static func date(_ milliseconds: String?) -> Date? {
        guard let milliseconds, let value = Double(milliseconds), value.isFinite else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
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
    /// Transfers only: the other account, which Actual stores as the payee.
    var transferAccountId: String? = nil
    /// The linked transaction in the other account.
    var transferId: String? = nil
    var transferReconciled: Bool? = nil
    /// The linked transaction is part of a split, which Actual would unbalance or move.
    var transferInSplit: Bool? = nil

    /// Reconciled transactions and transfers can be edited too, after any warning.
    var canEdit: Bool { !isParent && !isChild && transferInSplit != true }
    var isReconciled: Bool { reconciled == true }
    var title: String {
        // As in Actual's mobile register, a transfer names the other account and the direction.
        if transferAccountId != nil, let payeeName, !payeeName.isEmpty {
            return amount > 0 ? "Transfer from \(payeeName)" : "Transfer to \(payeeName)"
        }
        return payeeName.flatMap { $0.isEmpty ? nil : $0 } ?? "No payee"
    }
    /// An uncategorized transfer, such as one between two on-budget accounts, shows as a transfer.
    var detail: String { transferAccountId != nil && categoryId == nil ? "Transfer" : categoryName ?? "Uncategorized" }
}

struct Payee: Decodable, Identifiable, Sendable { let id: String; let name: String }

/// An account being compared with a balance from the bank. As in Actual, it is not saved.
struct Reconciliation: Equatable, Sendable {
    let accountID: String
    let targetBalance: Int
}

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
        FormatterCache.shared.formatter("display", currency, locale) {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = currency.isEmpty ? .decimal : .currency
            if !currency.isEmpty { formatter.currencyCode = currency }
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
            return formatter
        }
    }

    fileprivate static func formatted(_ minorUnits: Int, formatter: NumberFormatter) -> String {
        return formatter.string(from: NSDecimalNumber(decimal: Decimal(minorUnits) / 100)) ?? "—"
    }

    static func editable(_ minorUnits: Int, locale: Locale = .current) -> String {
        let formatter = FormatterCache.shared.formatter("editable", "", locale) {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
            return formatter
        }
        return formatter.string(from: NSDecimalNumber(decimal: Decimal(minorUnits) / 100)) ?? ""
    }

    /// Parse the whole localized input, without accepting fractional cents or floating-point rounding.
    static func parse(_ text: String, locale: Locale = .current) -> Int? {
        let formatter = FormatterCache.shared.formatter("parse", "", locale) {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            formatter.generatesDecimalNumbers = true
            return formatter
        }
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

/// Number formatters are costly to create, and every amount on screen needs one.
/// Cached formatters are configured once and never changed afterward.
private final class FormatterCache: Sendable {
    static let shared = FormatterCache()
    private let formatters = Mutex<[String: NumberFormatter]>([:])

    func formatter(_ purpose: String, _ currency: String, _ locale: Locale, make: () -> NumberFormatter) -> NumberFormatter {
        // Separators too: a changed number format need not change the identifier.
        let key = [purpose, currency, locale.identifier, locale.decimalSeparator ?? "", locale.groupingSeparator ?? ""]
            .joined(separator: "|")
        return formatters.withLock { formatters in
            if let formatter = formatters[key] { return formatter }
            let formatter = make()
            formatters[key] = formatter
            return formatter
        }
    }
}

enum BudgetDate {
    // Fixed formats in the Gregorian calendar; configured once, then only read.
    private static let monthFormatter = formatter("yyyy-MM")
    private static let dayFormatter = formatter("yyyy-MM-dd")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = format
        return formatter
    }
    static func month(_ date: Date) -> String { monthFormatter.string(from: date) }
    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func date(_ string: String) -> Date? { dayFormatter.date(from: string) }
}
