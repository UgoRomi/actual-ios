import AppIntents
import Foundation

/// An account, for Shortcuts to choose where a transaction goes.
struct AccountEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
    static let defaultQuery = AccountQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct AccountQuery: EntityQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [AccountEntity] {
        try await openAccounts().filter { identifiers.contains($0.id) }
    }
    @MainActor func suggestedEntities() async throws -> [AccountEntity] { try await openAccounts() }

    @MainActor private func openAccounts() async throws -> [AccountEntity] {
        let model = try await IntentSupport.openBudget()
        return (model.overview?.openAccounts ?? []).map { AccountEntity(id: $0.id, name: $0.name) }
    }
}

@MainActor
enum IntentSupport {
    /// The app's model with its last budget open, as opening the app does.
    static func openBudget() async throws -> AppModel {
        guard let model = AppModel.current else { throw IntentError.notReady }
        if !model.hasStarted { await model.start() }
        guard model.isBudgetOpen else { throw IntentError.noBudget }
        return model
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady, noBudget, noAccount, notSaved(String)
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "Actual is starting. Try again in a moment."
        case .noBudget: "Open a budget in Actual first."
        case .noAccount: "Add an account in Actual first."
        case .notSaved(let reason): "The transaction was not saved. \(reason)"
        }
    }
}

/// Adds a transaction, as the app's editor does: rules run, and the budget syncs.
struct AddTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Transaction"
    static let description = IntentDescription("Adds a transaction to your Actual budget.")

    @Parameter(title: "Amount", description: "How much was spent or received.")
    var amount: Double
    @Parameter(title: "Payee")
    var payee: String?
    @Parameter(title: "Account", description: "Leave empty to use your first on-budget account.")
    var account: AccountEntity?
    @Parameter(title: "Deposit", description: "Money received instead of spent.", default: false)
    var isDeposit: Bool
    @Parameter(title: "Notes")
    var notes: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$amount) at \(\.$payee) to \(\.$account)") {
            \.$isDeposit
            \.$notes
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentSupport.openBudget()
        let accounts = model.overview?.openAccounts ?? []
        guard let accountID = account?.id ?? accounts.first(where: { !$0.offbudget })?.id ?? accounts.first?.id
        else { throw IntentError.noAccount }
        let cents = Int((abs(amount) * 100).rounded())
        var arguments: [String: JSONValue] = [
            "accountId": .string(accountID), "date": .string(BudgetDate.day(Date())),
            "amount": .number(isDeposit ? cents : -cents), "notes": .string(notes ?? ""), "cleared": .bool(false),
            "categoryId": .null, "newId": .string(UUID().uuidString.lowercased()),
        ]
        let name = (payee ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = model.overview?.payees.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            arguments["payeeId"] = .string(match.id)
        } else if !name.isEmpty { arguments["payeeName"] = .string(name) }
        guard await model.perform("saveTransaction", arguments: arguments) else {
            throw IntentError.notSaved(model.errorMessage ?? "")
        }
        let formatted = Money.formatted(cents, currency: model.currency)
        let accountName = accounts.first { $0.id == accountID }?.name ?? "your account"
        return .result(dialog: "Added \(isDeposit ? "a deposit of " : "")\(formatted)\(name.isEmpty ? "" : " at \(name)") to \(accountName).")
    }
}

/// Says what is left to budget this month, or the savings of a tracking budget.
struct BudgetLeftIntent: AppIntent {
    static let title: LocalizedStringResource = "Budget Left"
    static let description = IntentDescription("Tells you what is left to budget this month in Actual.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let model = try await IntentSupport.openBudget()
        guard let budget = model.budget else { throw IntentError.noBudget }
        let amount: Int, label: String
        switch budget.budgetType {
        case .envelope:
            amount = budget.toBudget ?? 0
            label = amount < 0 ? "You have budgeted more than you have, by" : "Left to budget:"
        case .tracking:
            amount = budget.saved ?? 0
            label = budget.savedIsProjected ? "Projected savings:" : "Saved:"
        }
        let formatted = Money.formatted(abs(amount), currency: model.currency)
        return .result(value: Money.formatted(amount, currency: model.currency), dialog: "\(label) \(formatted).")
    }
}

struct ActualShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddTransactionIntent(), phrases: [
            "Add a transaction in \(.applicationName)",
            "Log spending in \(.applicationName)",
        ], shortTitle: "Add Transaction", systemImageName: "plus.circle")
        AppShortcut(intent: BudgetLeftIntent(), phrases: [
            "What's left to budget in \(.applicationName)",
            "How much is left in \(.applicationName)",
        ], shortTitle: "Budget Left", systemImageName: "chart.pie")
    }
}
