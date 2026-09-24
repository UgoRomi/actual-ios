import Foundation

extension AppModel {
    /// The loaded budget parts combined, for assertions.
    var snapshot: BudgetSnapshot? {
        guard let overview, let budget else { return nil }
        return BudgetSnapshot(overview: overview, budget: budget, transactions: transactions)
    }
}
