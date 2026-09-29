import Foundation
import Synchronization

enum JSONValue: Codable, Sendable, Equatable {
    /// Amounts are always exact integers; `double` carries other numbers, such as percentages.
    case null, bool(Bool), number(Int), double(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .number(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
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
        case .double(let value): try container.encode(value)
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

enum LoginMethod: String, Decodable, Sendable { case password, openid }

/// How a server lets people sign in, its active method first.
struct LoginOptions: Decodable, Sendable {
    let methods: [LoginMethod]
    /// False until someone signs in with OpenID; that person becomes the server owner.
    let ownerCreated: Bool
}

struct OpenIDStart: Decodable, Sendable { let url: String }

/// Actual's OpenID callback sends the session token to `returnURL/openid-cb?token=…`.
/// It accepts return addresses on the server's host or localhost.
enum OpenIDCallback {
    static let scheme = "actualnative"
    static let returnURL = "\(scheme)://localhost"

    static func token(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == "localhost", url.path == "/openid-cb",
              let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else { return nil }
        return token
    }
}

/// The open budget's metadata, accounts with balances, and payees.
struct BudgetOverview: Decodable, Sendable {
    let budgetName: String
    let cloudFileId: String?
    let currencyCode: String
    let syncWarning: SyncWarning?
    /// Actual's formatting settings for this budget.
    var format: BudgetFormat? = nil
    var accounts: [Account]
    let payees: [Payee]
    var tags: [Tag] = []

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
    /// Envelope budgets only: how To Budget adds up.
    let envelope: EnvelopeSummary?
    /// The month's notes, where Actual records money moved between categories.
    var notes: String? = nil
    /// Every group, including hidden groups and categories.
    let groups: [CategoryGroup]

    /// Groups and categories that are not hidden, as Actual lists them by default.
    var visibleGroups: [CategoryGroup] { groups(showingHidden: false) }

    func groups(showingHidden: Bool) -> [CategoryGroup] {
        guard !showingHidden else { return groups }
        return groups.filter { !$0.hidden }.map { group in
            var visible = group
            visible.categories = group.categories.filter { !$0.hidden }
            return visible
        }
    }

    var categories: [BudgetCategory] { groups.flatMap(\.categories) }
    var expenseCategories: [BudgetCategory] { categories.filter { !$0.isIncome } }
    var overspent: [BudgetCategory] { expenseCategories.filter { $0.balance < 0 } }

    /// Expense groups with the categories the filter shows, leaving out groups with none.
    /// Hidden groups and categories show only on request, as in Actual.
    func expenseGroups(_ filter: BudgetFilter, showingHidden: Bool = false) -> [CategoryGroup] {
        groups(showingHidden: showingHidden).compactMap { group in
            let categories = group.categories.filter { !$0.isIncome && filter.includes($0) }
            // Without a filter, an empty expense group still shows, so categories can be added to it.
            guard !categories.isEmpty || (filter == .all && !group.isIncome) else { return nil }
            var filtered = group
            filtered.categories = categories
            return filtered
        }
    }

    func count(_ filter: BudgetFilter, showingHidden: Bool = false) -> Int {
        groups(showingHidden: showingHidden).flatMap(\.categories).count { !$0.isIncome && filter.includes($0) }
    }
}

/// The Budget screen's quick filters for expense categories.
enum BudgetFilter: CaseIterable, Identifiable, Sendable {
    case all
    /// A negative balance, which the category's row shows in red.
    case overspent
    /// Budgeted, or for a long-term goal saved, less than the targets ask for.
    case underfunded

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .overspent: "Overspent"
        case .underfunded: "Underfunded"
        }
    }

    func includes(_ category: BudgetCategory) -> Bool {
        switch self {
        case .all: true
        case .overspent: category.balance < 0
        case .underfunded: (category.goalDifference ?? 0) < 0
        }
    }
}

/// Actual's envelope budget summary. To Budget is available funds, less last
/// month's overspending, what is budgeted, and what is held for next month.
struct EnvelopeSummary: Decodable, Sendable, Equatable {
    let income: Int
    let fromLastMonth: Int
    let availableFunds: Int
    /// Zero or negative.
    let lastMonthOverspent: Int
    /// Negative: budgeted amounts reduce To Budget.
    let budgeted: Int
    /// Held for next month, by hand or automatically.
    let forNextMonth: Int
    let manualHold: Int
    /// Income that rolls over automatically, as Actual's income carryover does.
    let autoHold: Int
}

enum BudgetType: String, Decodable, Sendable { case envelope, tracking }

/// Where money moves from or to: a category, or the envelope budget's To Budget.
enum BudgetSource: Hashable, Sendable {
    case toBudget
    case category(String)
    var id: String { if case .category(let id) = self { id } else { "to-budget" } }
}

/// Actual's budget menu actions, as desktop-client's useBudgetActions names them.
enum BudgetAction: Sendable, Equatable {
    case copyLastMonth, setZero
    /// Every category's budget set to its average over 3, 6, or 12 months.
    case setAverage(months: Int)
    case copyLastMonthFor(category: String)
    case setAverageFor(category: String, months: Int)
    /// Overspending rolls over into next month instead of reducing To Budget.
    case rollover(category: String, enabled: Bool)
    /// Moves part of a category's balance to another category or To Budget.
    case transfer(from: String, to: BudgetSource, amount: Int)
    /// Covers a category's overspending from another category or To Budget.
    case coverOverspending(category: String, from: BudgetSource, amount: Int)
    /// Budgets money left in To Budget to a category.
    case transferAvailable(to: String, amount: Int)
    /// Takes money from a category's balance to cover a negative To Budget.
    case coverOverbudgeted(from: String, amount: Int)
    case hold(amount: Int)
    case resetHold
    /// Stops income from rolling over automatically into next month.
    case disableAutoHold

    var name: String {
        switch self {
        case .copyLastMonth: "copy-last"
        case .setZero: "set-zero"
        case .setAverage(let months): "set-\(months)-avg"
        case .copyLastMonthFor: "copy-single-last"
        case .setAverageFor: "set-single-avg"
        case .rollover: "carryover"
        case .transfer: "transfer-category"
        case .coverOverspending: "cover-overspending"
        case .transferAvailable: "transfer-available"
        case .coverOverbudgeted: "cover-overbudgeted"
        case .hold: "hold"
        case .resetHold: "reset-hold"
        case .disableAutoHold: "disable-auto-hold"
        }
    }

    var arguments: [String: JSONValue] {
        switch self {
        case .copyLastMonth, .setZero, .setAverage, .resetHold, .disableAutoHold: [:]
        case .copyLastMonthFor(let category): ["category": .string(category)]
        case .setAverageFor(let category, let months): ["category": .string(category), "months": .number(months)]
        case .rollover(let category, let enabled): ["category": .string(category), "flag": .bool(enabled)]
        case .transfer(let from, let to, let amount):
            ["from": .string(from), "to": .string(to.id), "amount": .number(amount)]
        case .coverOverspending(let category, let from, let amount):
            ["to": .string(category), "from": .string(from.id), "amount": .number(amount)]
        case .transferAvailable(let to, let amount): ["category": .string(to), "amount": .number(amount)]
        case .coverOverbudgeted(let from, let amount): ["category": .string(from), "amount": .number(amount)]
        case .hold(let amount): ["amount": .number(amount)]
        }
    }
}

struct Account: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    var balance: Int
    let offbudget: Bool
    let closed: Bool
    var bankSyncEnabled: Bool? = nil
    var bankSyncStatus: String? = nil
    var lastBankSync: String? = nil
    var clearedBalance: Int? = nil
    /// The latest balance reported by a linked bank.
    var bankBalance: Int? = nil
    var lastReconciled: String? = nil
    var notes: String? = nil

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
    var categories: [BudgetCategory]
    var hidden = false
    var isIncome = false
    var notes: String? = nil
    /// Actual's group totals, which include the group's hidden categories.
    var budgeted = 0
    var spent = 0
    var balance = 0
}

struct BudgetCategory: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    var hidden = false
    var notes: String? = nil
    let budgeted: Int
    let spent: Int
    let balance: Int
    let isIncome: Bool
    /// Targets set in Actual's budget automations editor or in the category's notes.
    let hasTargets: Bool
    /// The amount the category's targets ask for, set when targets are applied to the month.
    let goal: Int?
    /// A long-term goal, which Actual compares with the balance instead of the budgeted amount.
    let longGoal: Bool
    /// Overspending rolls over to next month instead of reducing To Budget.
    let carryover: Bool

    /// How far the category is from its goal, as Actual's balance tooltip shows it.
    var goalDifference: Int? {
        goal.map { (longGoal ? balance : budgeted) - $0 }
    }
}

struct Transaction: Decodable, Identifiable, Sendable {
    let id: String
    var accountId: String
    var date: String
    var payeeId: String?
    var payeeName: String?
    var categoryId: String?
    var categoryName: String?
    var amount: Int
    var notes: String?
    var cleared: Bool
    var isParent: Bool
    var isChild: Bool
    var isTransfer: Bool

    var reconciled: Bool?
    /// Transfers only: the other account, which Actual stores as the payee.
    var transferAccountId: String? = nil
    /// The linked transaction in the other account.
    var transferId: String? = nil
    var transferReconciled: Bool? = nil
    /// The linked transaction is part of a split, which Actual would unbalance or move.
    var transferInSplit: Bool? = nil
    /// A split's parts, for its parent only.
    var splits: [SplitPart]? = nil

    /// Reconciled transactions, transfers, and splits can be edited too, after any warning.
    /// A transfer linked to part of a split is edited from the split, as Actual does.
    var canEdit: Bool { !isChild && transferInSplit != true }
    var isReconciled: Bool { reconciled == true }
    var title: String {
        // As in Actual's mobile register, a transfer names the other account and the direction.
        if transferAccountId != nil, let payeeName, !payeeName.isEmpty {
            return amount > 0 ? "Transfer from \(payeeName)" : "Transfer to \(payeeName)"
        }
        return payeeName.flatMap { $0.isEmpty ? nil : $0 } ?? "No payee"
    }
    /// An uncategorized transfer, such as one between two on-budget accounts, shows as a transfer.
    var detail: String {
        if isParent { return "Split" + ((splits?.count).map { " · \($0) parts" } ?? "") }
        return transferAccountId != nil && categoryId == nil ? "Transfer" : categoryName ?? "Uncategorized"
    }
}

/// One part of a split transaction.
struct SplitPart: Decodable, Identifiable, Sendable, Equatable {
    let id: String
    var amount: Int
    var categoryId: String?
    var categoryName: String?
    var notes: String
    var isTransfer: Bool
    var payeeId: String? = nil
    var payeeName: String? = nil
    /// A transfer part's other account.
    var transferAccountId: String? = nil
}

/// A transaction edit shown before the engine saves it, as Actual's mobile app
/// shows edits right away. It applies to the register and balances as last
/// loaded, so applying it where the engine has already saved it changes nothing.
enum TransactionChange: Sendable {
    /// Adds a transaction, or replaces the one with its ID.
    case save(Transaction)
    /// Deletes a transaction and, for a transfer, its linked transaction.
    case delete(id: String)
    case setCleared(id: String, cleared: Bool)
    case unlock(id: String)

    /// Whether the budget month may change: clearing and unlocking change only balances.
    var changesBudget: Bool {
        switch self {
        case .save, .delete: true
        case .setCleared, .unlock: false
        }
    }

    func apply(to transactions: inout [Transaction], accounts: inout [Account]) {
        switch self {
        case .save(let saved):
            let previous = transactions.firstIndex { $0.id == saved.id }.map { transactions.remove(at: $0) }
            Self.insert(saved, into: &transactions)
            Self.adjust(&accounts, removing: previous, adding: saved)
            // Actual gives a transfer's linked transaction the same amount and notes.
            guard let previous, let linkedID = previous.transferId, previous.transferAccountId == saved.transferAccountId,
                  let index = transactions.firstIndex(where: { $0.id == linkedID }) else { return }
            var linked = transactions[index]
            let before = linked
            linked.amount = -saved.amount
            linked.notes = saved.notes
            transactions[index] = linked
            Self.adjust(&accounts, removing: before, adding: linked)
        case .delete(let id):
            guard let index = transactions.firstIndex(where: { $0.id == id }) else { return }
            let removed = transactions.remove(at: index)
            Self.adjust(&accounts, removing: removed, adding: nil)
            if let linkedID = removed.transferId, let linked = transactions.firstIndex(where: { $0.id == linkedID }) {
                Self.adjust(&accounts, removing: transactions.remove(at: linked), adding: nil)
            }
        case .setCleared(let id, let cleared):
            guard let index = transactions.firstIndex(where: { $0.id == id }), transactions[index].cleared != cleared else { return }
            let before = transactions[index]
            transactions[index].cleared = cleared
            Self.adjust(&accounts, removing: before, adding: transactions[index])
        case .unlock(let id):
            for index in transactions.indices {
                if transactions[index].id == id { transactions[index].reconciled = false }
                if transactions[index].transferId == id { transactions[index].transferReconciled = false }
            }
        }
    }

    /// In the engine's order: newest date first, then by ID.
    private static func insert(_ transaction: Transaction, into transactions: inout [Transaction]) {
        let index = transactions.firstIndex {
            $0.date < transaction.date || ($0.date == transaction.date && $0.id > transaction.id)
        } ?? transactions.endIndex
        transactions.insert(transaction, at: index)
    }

    /// Moves a transaction's amount out of, and into, its account's balances.
    private static func adjust(_ accounts: inout [Account], removing old: Transaction?, adding new: Transaction?) {
        for (transaction, sign) in [(old, -1), (new, 1)] {
            guard let transaction, let index = accounts.firstIndex(where: { $0.id == transaction.accountId }) else { continue }
            accounts[index].balance += sign * transaction.amount
            if transaction.cleared, let cleared = accounts[index].clearedBalance {
                accounts[index].clearedBalance = cleared + sign * transaction.amount
            }
        }
    }
}

struct Payee: Decodable, Identifiable, Sendable { let id: String; let name: String }

/// A tag for #tags in notes, as Actual's tags page lists them.
struct Tag: Decodable, Identifiable, Sendable, Hashable {
    let id: String
    let tag: String
    /// A hex color, such as #7C3AED; nil uses Actual's default tag color.
    let color: String?
    let description: String?
    let hidden: Bool
}

/// Actual's #tags in notes: a # then anything but whitespace or #, where ## escapes a tag.
enum NoteTags {
    static func extract(_ notes: String?) -> [String] {
        guard let notes, notes.contains("#") else { return [] }
        var tags: [String] = []
        var index = notes.startIndex
        while let hash = notes[index...].firstIndex(of: "#") {
            let next = notes.index(after: hash)
            // A doubled # is an escaped tag.
            if hash > notes.startIndex, notes[notes.index(before: hash)] == "#" { index = next; continue }
            if next < notes.endIndex, notes[next] == "#" { index = notes.index(after: next); continue }
            let end = notes[next...].firstIndex { $0 == "#" || $0.isWhitespace } ?? notes.endIndex
            if end > next {
                let tag = String(notes[next..<end])
                if !tags.contains(tag) { tags.append(tag) }
            }
            index = end
            if index == notes.endIndex { break }
        }
        return tags
    }
}

/// A payee on Actual's payees page: how many rules use it, and whether any transaction does.
struct ManagedPayee: Decodable, Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let ruleCount: Int
    let unused: Bool
}

/// An account being compared with a balance from the bank. As in Actual, it is not saved.
struct Reconciliation: Equatable, Sendable {
    let accountID: String
    let targetBalance: Int
}

/// A transaction, or one part of a split, as Actual's category and uncategorized lists show them.
struct CategoryEntry: Identifiable, Sendable {
    enum Filter: Hashable, Sendable {
        /// A category's transactions in a month (`yyyy-MM`).
        case category(id: String, month: String)
        /// On-budget transactions without a category, other than transfers between on-budget accounts.
        case uncategorized
    }

    /// The whole transaction, which opens in the editor.
    let transaction: Transaction
    let part: SplitPart?
    var id: String { part?.id ?? transaction.id }
    var amount: Int { part?.amount ?? transaction.amount }
    var notes: String? { part.map(\.notes) ?? transaction.notes }

    /// Newest first, as the register orders them, with a split's parts in its order.
    static func entries(_ transactions: [Transaction], filter: Filter, accounts: [Account]) -> [CategoryEntry] {
        let offBudget = Set(accounts.filter(\.offbudget).map(\.id))
        func matches(category: String?, transferAccount: String?) -> Bool {
            switch filter {
            case .category(let id, _): return category == id
            case .uncategorized:
                // Actual's uncategorizedTransactions: a transfer counts only when it leaves the budget.
                return category == nil && (transferAccount == nil || offBudget.contains(transferAccount!))
            }
        }
        return transactions.flatMap { transaction -> [CategoryEntry] in
            guard !transaction.isChild else { return [] }
            if case .category(_, let month) = filter, !transaction.date.hasPrefix(month) { return [] }
            if case .uncategorized = filter, offBudget.contains(transaction.accountId) { return [] }
            if transaction.isParent {
                // Transfers inside a split are left to Actual, which links them to another account.
                return (transaction.splits ?? []).filter { !$0.isTransfer && matches(category: $0.categoryId, transferAccount: nil) }
                    .map { CategoryEntry(transaction: transaction, part: $0) }
            }
            return matches(category: transaction.categoryId, transferAccount: transaction.transferAccountId)
                ? [CategoryEntry(transaction: transaction, part: nil)] : []
        }
    }
}

struct TransactionSection: Identifiable {
    let date: String
    let transactions: [Transaction]
    var id: String { date }

    /// Filter once, then group once. Section rendering must never rescan the full register.
    static func grouped(_ transactions: [Transaction], accountID: String? = nil,
                        search: String = "", currency: String = "", locale: Locale = Money.locale) -> [Self] {
        let formatter = search.isEmpty ? nil : Money.formatter(currency: currency, locale: locale)
        let matching = transactions.filter { transaction in
            guard !transaction.isChild, accountID == nil || transaction.accountId == accountID else { return false }
            guard let formatter else { return true }
            return transaction.title.localizedCaseInsensitiveContains(search)
                || transaction.detail.localizedCaseInsensitiveContains(search)
                || (transaction.notes ?? "").localizedCaseInsensitiveContains(search)
                // A split matches its parts' categories and notes.
                || (transaction.isParent && (transaction.categoryName ?? "").localizedCaseInsensitiveContains(search))
                || (transaction.splits ?? []).contains {
                    ($0.categoryName ?? "").localizedCaseInsensitiveContains(search)
                        || $0.notes.localizedCaseInsensitiveContains(search)
                }
                || Money.formatted(transaction.amount, formatter: formatter).localizedCaseInsensitiveContains(search)
        }
        let grouped = Dictionary(grouping: matching, by: \.date)
        // Preserve the engine's ordering within each day, including its ID tie-breaker.
        return grouped.keys.sorted(by: >).map { Self(date: $0, transactions: grouped[$0] ?? []) }
    }
}

/// Actual's formatting settings, which sync between devices. Unset ones follow the device.
struct BudgetFormat: Decodable, Sendable, Equatable {
    /// comma-dot, dot-comma, space-comma, apostrophe-dot, or comma-dot-in.
    var numberFormat: String?
    var hideFraction: Bool
    /// Such as MM/dd/yyyy.
    var dateFormat: String?
    /// 0 is Sunday.
    var firstDayOfWeekIdx: Int?
    /// How far ahead registers list upcoming scheduled transactions: 1, 7, 14, oneMonth, or currentMonth.
    var upcomingLength: String? = nil

    static let numberFormats: [(value: String, label: String)] = [
        ("comma-dot", "1,000.33"), ("dot-comma", "1.000,33"), ("space-comma", "1\u{202F}000,33"),
        ("apostrophe-dot", "1’000.33"), ("comma-dot-in", "1,00,000.33"),
    ]
    static let dateFormats = ["MM/dd/yyyy", "dd/MM/yyyy", "yyyy-MM-dd", "MM.dd.yyyy", "dd.MM.yyyy", "dd-MM-yyyy"]

    /// The locale Actual formats numbers with for this setting (shared/util.ts getNumberFormat).
    var locale: Locale? {
        switch numberFormat {
        case "comma-dot": Locale(identifier: "en_US")
        case "dot-comma": Locale(identifier: "de_DE")
        case "space-comma": Locale(identifier: "fr_FR")
        case "apostrophe-dot": Locale(identifier: "de_CH")
        case "comma-dot-in": Locale(identifier: "en_IN")
        default: nil
        }
    }
}

enum Money {
    private static let preference = Mutex<(locale: Locale?, hideFraction: Bool)>((nil, false))

    /// Formats amounts as the budget's settings ask, as Actual does on every device.
    static func configure(_ format: BudgetFormat?) {
        preference.withLock { $0 = (format?.locale, format?.hideFraction ?? false) }
    }
    /// The budget's number format, or the device's.
    static var locale: Locale { preference.withLock { $0.locale } ?? .current }
    static var hidesFraction: Bool { preference.withLock { $0.hideFraction } }

    static func formatted(_ minorUnits: Int, currency: String = "", locale: Locale = Money.locale) -> String {
        formatted(minorUnits, formatter: formatter(currency: currency, locale: locale))
    }

    fileprivate static func formatter(currency: String, locale: Locale) -> NumberFormatter {
        let digits = hidesFraction ? 0 : 2
        return FormatterCache.shared.formatter("display-\(digits)", currency, locale) {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = currency.isEmpty ? .decimal : .currency
            if !currency.isEmpty { formatter.currencyCode = currency }
            formatter.minimumFractionDigits = digits
            formatter.maximumFractionDigits = digits
            return formatter
        }
    }

    fileprivate static func formatted(_ minorUnits: Int, formatter: NumberFormatter) -> String {
        return formatter.string(from: NSDecimalNumber(decimal: Decimal(minorUnits) / 100)) ?? "—"
    }

    static func editable(_ minorUnits: Int, locale: Locale = Money.locale) -> String {
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

    /// Parse the whole localized input: a number, or a calculation with + − × ÷ and parentheses,
    /// as Actual's amount fields accept. Arithmetic is exact, without floating-point rounding.
    /// As in Actual, a calculation's result is rounded to the cent; a lone number may not have fractional cents.
    static func parse(_ text: String, locale: Locale = Money.locale) -> Int? {
        let formatter = FormatterCache.shared.formatter("parse", "", locale) {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            formatter.generatesDecimalNumbers = true
            return formatter
        }
        // As Actual does, ignore spaces, including a space used as the grouping separator.
        var input = text.replacingOccurrences(of: formatter.minusSign ?? "-", with: "-")
        input.unicodeScalars.removeAll { CharacterSet.whitespacesAndNewlines.contains($0) }
        let symbols: [Character: Character] = ["−": "-", "×": "*", "÷": "/"]
        var calculation = Calculation(characters: input.map { symbols[$0] ?? $0 }) { number($0, formatter: formatter) }
        guard let value = calculation.expression(), calculation.isAtEnd, !value.isNaN else { return nil }
        var cents = value * 100
        // Actual's Math.round: to the nearest cent, halves upward.
        var shifted = cents + Decimal(sign: .plus, exponent: -1, significand: 5)
        NSDecimalRound(&cents, &shifted, 0, .down)
        guard calculation.calculated || cents == value * 100 else { return nil }
        // Actual stores exact JS integers; stay within that range at the bridge boundary.
        guard cents >= -9_007_199_254_740_991, cents <= 9_007_199_254_740_991 else { return nil }
        return NSDecimalNumber(decimal: cents).intValue
    }

    /// One number of an amount entry, in the locale's format.
    private static func number(_ text: String, formatter: NumberFormatter) -> Decimal? {
        let decimalSeparator = formatter.decimalSeparator ?? "."
        let groupingSeparator = formatter.groupingSeparator ?? ","
        var normalized = text.replacingOccurrences(of: groupingSeparator, with: "")
        normalized = normalized.replacingOccurrences(of: decimalSeparator, with: ".")
        normalized = normalized.map { character in
            character.wholeNumberValue.map(String.init) ?? String(character)
        }.joined()
        guard normalized.range(of: "^(?:[0-9]+\\.?[0-9]*|\\.[0-9]+)$", options: .regularExpression) != nil,
              formatter.number(from: text) != nil else { return nil }
        return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// Actual's amount arithmetic (loot-core's `evalArithmetic`) with exact decimals. Like Actual's
/// calculator keypad, it offers + - * / and parentheses, but not `^`.
private struct Calculation {
    let characters: [Character]
    let number: (String) -> Decimal?
    var index = 0
    /// Whether the input used an operator or parentheses, rather than being a lone number.
    var calculated = false

    var isAtEnd: Bool { index == characters.count }
    private var next: Character? { index < characters.count ? characters[index] : nil }

    mutating func expression() -> Decimal? {
        guard var value = term() else { return nil }
        while let operation = next, operation == "+" || operation == "-" {
            index += 1
            calculated = true
            guard let right = term() else { return nil }
            value = operation == "+" ? value + right : value - right
        }
        return value
    }

    private mutating func term() -> Decimal? {
        guard var value = factor() else { return nil }
        while let operation = next, operation == "*" || operation == "/" {
            index += 1
            calculated = true
            guard let right = factor() else { return nil }
            value = operation == "*" ? value * right : value / right
        }
        return value
    }

    private mutating func factor() -> Decimal? {
        switch next {
        case "-":
            index += 1
            return factor().map { -$0 }
        case "+":
            index += 1
            return factor()
        case "(":
            index += 1
            calculated = true
            guard let value = expression(), next == ")" else { return nil }
            index += 1
            return value
        default:
            let start = index
            while let character = next, !"+-*/()".contains(character) { index += 1 }
            return start == index ? nil : number(String(characters[start..<index]))
        }
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
    private static let preference = Mutex<(dateFormat: String?, firstWeekday: Int?)>((nil, nil))

    /// Shows dates and weeks as the budget's settings ask.
    static func configure(_ format: BudgetFormat?) {
        preference.withLock {
            $0 = (format?.dateFormat, format?.firstDayOfWeekIdx.map { $0 + 1 })
        }
    }

    /// The device's calendar, starting the week on the budget's first day.
    static var calendar: Calendar {
        var calendar = Calendar.autoupdatingCurrent
        if let weekday = preference.withLock({ $0.firstWeekday }) { calendar.firstWeekday = weekday }
        return calendar
    }

    /// A day as the budget's date format writes it, or in the device's medium style.
    static func display(_ day: String) -> String {
        guard let date = Self.date(day) else { return day }
        guard let pattern = preference.withLock({ $0.dateFormat }) else {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    static func month(_ date: Date) -> String { monthFormatter.string(from: date) }
    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func date(_ string: String) -> Date? { dayFormatter.date(from: string) }
}
