import Foundation

/// Transaction edits show before the engine saves them, never block the app,
/// and end up matching what the engine saved.
@main struct OptimisticEdits {
    @MainActor static func main() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("optimistic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(engine: try EngineClient(dataDirectory: directory, resourceDirectory: resources, useKeychain: false))
        try require(await model.perform("demo"), "The demo budget did not open")
        guard let account = model.overview?.openAccounts.first else { throw EngineFailure("No demo account") }
        let rows = model.transactions.filter { $0.accountId == account.id && $0.canEdit && !$0.isReconciled && !$0.isTransfer }
        guard rows.count >= 2 else { throw EngineFailure("Too few demo transactions") }

        // Clearing shows at once, before the engine has saved it, and the app stays usable.
        let first = rows[0], second = rows[1]
        let clearing = Task { await model.edit("setCleared", arguments: ["id": .string(first.id), "cleared": .bool(!first.cleared)],
                                               showing: .setCleared(id: first.id, cleared: !first.cleared)) }
        try await until("The cleared change should show") { shown(model, first.id)?.cleared == !first.cleared }
        try require(model.syncStatus != "Saved on this device", "The change showed only after the engine saved it")
        try require(!model.isBusy, "An edit should not block the app")
        // A second edit while the first is saving.
        let secondClearing = Task { await model.edit("setCleared", arguments: ["id": .string(second.id), "cleared": .bool(!second.cleared)],
                                                     showing: .setCleared(id: second.id, cleared: !second.cleared)) }
        let (cleared, clearedSecond) = (await clearing.value, await secondClearing.value)
        try require(cleared && clearedSecond, "Clearing failed: \(model.errorMessage ?? "")")
        try require(shown(model, first.id)?.cleared == !first.cleared && shown(model, second.id)?.cleared == !second.cleared,
                     "Both cleared changes should remain after saving")
        print("PASS: clearing shows before saving, without blocking a second edit")

        // A new transaction shows at once and keeps its ID once saved.
        let id = UUID().uuidString.lowercased()
        let draft = Transaction(id: id, accountId: account.id, date: "2026-09-24", payeeId: nil, payeeName: "Optimistic café",
                                categoryId: nil, categoryName: "Uncategorized", amount: -4321, notes: "Shown first",
                                cleared: false, isParent: false, isChild: false, isTransfer: false, reconciled: false)
        let balance = model.overview?.accounts.first { $0.id == account.id }?.balance ?? 0
        let adding = Task { await model.edit("saveTransaction", arguments: [
            "newId": .string(id), "accountId": .string(account.id), "date": .string(draft.date),
            "amount": .number(-4321), "notes": .string("Shown first"), "cleared": .bool(false), "payeeName": .string("Optimistic café"),
        ], showing: .save(draft)) }
        try await until("The new transaction should show") { shown(model, id) != nil }
        try require(model.overview?.accounts.first { $0.id == account.id }?.balance == balance - 4321, "The balance should include it at once")
        let added = await adding.value
        try require(added, "Adding failed: \(model.errorMessage ?? "")")
        try require(shown(model, id)?.payeeName == "Optimistic café", "The saved transaction should keep its ID")
        print("PASS: a new transaction shows at once and keeps its ID")

        // Deleting shows at once.
        let deleting = Task { await model.edit("deleteTransaction", arguments: ["id": .string(id)], showing: .delete(id: id)) }
        try await until("The deletion should show") { shown(model, id) == nil }
        let deleted = await deleting.value
        try require(deleted && shown(model, id) == nil, "Deleting failed: \(model.errorMessage ?? "")")
        print("PASS: deleting shows at once")

        // A rejected edit is undone and explained.
        var invalid = draft
        invalid.date = "not a date"
        let rejected = await model.edit("saveTransaction", arguments: [
            "newId": .string(UUID().uuidString.lowercased()), "accountId": .string(account.id), "date": .string(invalid.date), "amount": .number(-1),
        ], showing: .save(transactionCopy(invalid, id: "rejected")))
        try require(!rejected && shown(model, "rejected") == nil, "A rejected edit should be undone")
        try require(model.errorMessage == "Choose a valid date.", "A rejected edit should explain why: \(model.errorMessage ?? "")")
        print("PASS: a rejected edit is undone and explained")

        // What shows matches the engine.
        let shownRows = model.transactions.map { "\($0.id) \($0.amount) \($0.cleared)" }
        let shownBalances = model.overview?.accounts.map { "\($0.id) \($0.balance) \($0.clearedBalance ?? 0)" }
        await model.refresh()
        try require(model.transactions.map { "\($0.id) \($0.amount) \($0.cleared)" } == shownRows, "The register should match the engine")
        try require(model.overview?.accounts.map { "\($0.id) \($0.balance) \($0.clearedBalance ?? 0)" } == shownBalances,
                     "Balances should match the engine")
        print("PASS: the shown register and balances match the engine")
    }

    @MainActor static func shown(_ model: AppModel, _ id: String) -> Transaction? { model.transactions.first { $0.id == id } }

    static func transactionCopy(_ transaction: Transaction, id: String) -> Transaction {
        Transaction(id: id, accountId: transaction.accountId, date: transaction.date, payeeId: nil, payeeName: nil,
                    categoryId: nil, categoryName: nil, amount: transaction.amount, notes: nil, cleared: false,
                    isParent: false, isChild: false, isTransfer: false, reconciled: false)
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw EngineFailure(message) }
    }

    /// Yields to the edit's task, without letting the engine finish first.
    @MainActor static func until(_ message: String, predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        throw EngineFailure(message)
    }
}
