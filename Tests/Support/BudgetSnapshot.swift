import Foundation

/// The budget parts combined, so tests can inspect one consistent value.
struct BudgetSnapshot: Sendable {
    let overview: BudgetOverview
    let budget: BudgetMonth
    let transactions: [Transaction]

    static func load(_ engine: EngineClient, month: String) async throws -> BudgetSnapshot {
        BudgetSnapshot(
            overview: try await engine.call("overview", as: BudgetOverview.self),
            budget: try await engine.call(
                "budgetMonth", arguments: ["month": .string(month)], as: BudgetMonth.self),
            transactions: try await engine.call("register", as: [Transaction].self))
    }

    var budgetName: String { overview.budgetName }
    var cloudFileId: String? { overview.cloudFileId }
    var syncWarning: String? { overview.syncWarning?.message }
    var accounts: [Account] { overview.accounts }
    var openAccounts: [Account] { overview.openAccounts }
    var payees: [Payee] { overview.payees }
    var month: String { budget.month }
    var budgetType: BudgetType { budget.budgetType }
    var toBudget: Int? { budget.toBudget }
    var saved: Int? { budget.saved }
    var savedIsProjected: Bool { budget.savedIsProjected }
    var totalBudgeted: Int { budget.totalBudgeted }
    var totalSpent: Int { budget.totalSpent }
    var groups: [CategoryGroup] { budget.groups }
    var categories: [BudgetCategory] { budget.categories }
}
