import Foundation

extension EngineSmoke {
  /// Reconciles a demo account the way Actual's mobile web app does.
  static func reconciliation(data: URL, resources: URL) async throws {
    let engine = try EngineClient(
      dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    let budget = try await activeBudget(engine)
    func sql(_ statement: String, _ params: [Any] = []) throws -> [[String: Any]] {
      try query(data: data, resources: resources, budget: budget, statement, params)
    }
    func flags(_ id: String) throws -> [(cleared: Bool, reconciled: Bool)] {
      try sql(
        "SELECT cleared, reconciled FROM transactions WHERE (id = ? OR parent_id = ?) AND tombstone = 0",
        [id, id]
      ).map { (($0["cleared"] as? Int64) == 1, ($0["reconciled"] as? Int64) == 1) }
    }
    func expectFailure(_ method: String, _ arguments: [String: JSONValue], _ message: String) async throws {
      var failed = false
      do { _ = try await engine.call(method, arguments: arguments) } catch {
        failed = true
        precondition(error.localizedDescription.contains(message), "Unexpected error: \(error.localizedDescription)")
      }
      precondition(failed, "\(method) should have failed")
    }

    var current = try await snapshot(engine)
    guard let split = current.transactions.first(where: { $0.isParent }),
      let account = current.accounts.first(where: { $0.id == split.accountId })
    else { throw EngineFailure("Demo fixture has no split transaction") }
    let id = JSONValue.string(account.id)
    func reported(_ snapshot: BudgetSnapshot) -> Int? {
      snapshot.accounts.first { $0.id == account.id }?.clearedBalance
    }
    // Split parents carry their children's total, as Actual's binding counts them.
    func expected(_ snapshot: BudgetSnapshot) -> Int {
      snapshot.transactions.filter { $0.accountId == account.id && $0.cleared && !$0.isChild }
        .reduce(0) { $0 + $1.amount }
    }
    precondition(reported(current) == expected(current), "Cleared balance differs from the register")
    precondition(account.lastReconciled == nil && account.bankBalance == nil)

    // A split's cleared state carries to its children.
    _ = try await engine.call("setCleared", arguments: ["id": .string(split.id), "cleared": .bool(!split.cleared)])
    let toggled = try flags(split.id)
    precondition(toggled.count > 1 && toggled.allSatisfy { $0.cleared == !split.cleared })
    _ = try await engine.call("setCleared", arguments: ["id": .string(split.id), "cleared": .bool(true)])
    let restored = try flags(split.id)
    precondition(restored.allSatisfy(\.cleared))

    // Transfers can be cleared on one side only, as in Actual.
    guard let other = current.openAccounts.first(where: { $0.id != account.id && $0.offbudget == account.offbudget }),
      let transferPayee = try sql("SELECT id FROM payees WHERE transfer_acct = ? AND tombstone = 0", [other.id])
        .first?["id"] as? String
    else { throw EngineFailure("Demo fixture has no second account for a transfer") }
    _ = try await engine.call(
      "saveTransaction",
      arguments: [
        "accountId": id, "date": .string(BudgetDate.day(Date())), "payeeId": .string(transferPayee),
        "categoryId": .null, "amount": .number(-777), "notes": .string("Reconcile transfer"),
        "cleared": .bool(false),
      ])
    current = try await snapshot(engine)
    guard let transfer = current.transactions.first(where: { $0.notes == "Reconcile transfer" && $0.accountId == account.id }),
      transfer.isTransfer,
      let otherSide = try sql("SELECT transferred_id FROM transactions WHERE id = ?", [transfer.id])
        .first?["transferred_id"] as? String
    else { throw EngineFailure("Transfer was not created") }
    let otherBefore = try flags(otherSide)
    _ = try await engine.call("setCleared", arguments: ["id": .string(transfer.id), "cleared": .bool(true)])
    let (side, otherAfter) = (try flags(transfer.id), try flags(otherSide))
    precondition(side.first?.cleared == true)
    precondition(otherAfter.map(\.cleared) == otherBefore.map(\.cleared), "Clearing one side changed the other")

    guard let pending = current.transactions.first(where: {
      $0.accountId == account.id && $0.canEdit && !$0.isReconciled
    }) else { throw EngineFailure("Demo account has no ordinary transaction") }
    _ = try await engine.call("setCleared", arguments: ["id": .string(pending.id), "cleared": .bool(false)])
    current = try await snapshot(engine)
    let cleared = expected(current)
    precondition(reported(current) == cleared)

    // An adjustment covers the difference from the bank, with today's date.
    let target = cleared + 1234
    _ = try await engine.call("createReconciliationTransaction", arguments: ["accountId": id, "targetBalance": .number(target)])
    current = try await snapshot(engine)
    guard let adjustment = current.transactions.first(where: {
      $0.accountId == account.id && $0.notes == "Reconciliation balance adjustment"
    }) else { throw EngineFailure("Reconciliation transaction missing") }
    precondition(adjustment.amount == 1234 && adjustment.cleared && !adjustment.isReconciled)
    precondition(adjustment.date == BudgetDate.day(Date()))
    precondition(reported(current) == target)
    // Nothing to adjust once balanced.
    let count = current.transactions.count
    _ = try await engine.call("createReconciliationTransaction", arguments: ["accountId": id, "targetBalance": .number(target)])
    let unchanged = try await snapshot(engine)
    precondition(unchanged.transactions.count == count)

    // A requested lock fails if the balance no longer matches.
    func lockedCount() throws -> Int64? {
      try sql("SELECT count(*) AS n FROM transactions WHERE reconciled = 1 AND tombstone = 0").first?["n"] as? Int64
    }
    let lockedBefore = try lockedCount()
    try await expectFailure(
      "finishReconciliation", ["accountId": id, "targetBalance": .number(target + 1), "lock": .bool(true)],
      "cleared balance changed")
    let lockedAfter = try lockedCount()
    let refused = try await snapshot(engine)
    precondition(lockedAfter == lockedBefore && refused.accounts.first { $0.id == account.id }?.lastReconciled == nil)

    let started = Date()
    _ = try await engine.call("finishReconciliation", arguments: ["accountId": id, "targetBalance": .number(target), "lock": .bool(true)])
    current = try await snapshot(engine)
    let unlocked = try sql(
      "SELECT count(*) AS n FROM transactions WHERE acct = ? AND cleared = 1 AND reconciled = 0 AND tombstone = 0",
      [account.id]
    ).first?["n"] as? Int64
    precondition(unlocked == 0, "Every cleared transaction, including split children, must lock")
    let stillPending = try flags(pending.id).first
    precondition(stillPending?.reconciled == false, "Uncleared transactions must stay unlocked")
    guard let reconciledAt = current.accounts.first(where: { $0.id == account.id })?.lastReconciledDate
    else { throw EngineFailure("Reconciliation time missing") }
    precondition(abs(reconciledAt.timeIntervalSince(started)) < 60)
    precondition(current.transactions.first { $0.id == adjustment.id }?.isReconciled == true)

    // Reconciled transactions need unlocking before their cleared state changes,
    // and confirmation before an edit.
    try await expectFailure("setCleared", ["id": .string(adjustment.id), "cleared": .bool(false)], "Unlock")
    let edit: [String: JSONValue] = [
      "id": .string(adjustment.id), "accountId": id, "date": .string(adjustment.date),
      "payeeId": .null, "categoryId": .string(adjustment.categoryId ?? ""), "amount": .number(1234),
      "notes": .string("Confirmed edit"), "cleared": .bool(false),
    ]
    try await expectFailure("saveTransaction", edit, "reconciled after you opened it")
    try await expectFailure("deleteTransaction", ["id": .string(adjustment.id)], "reconciled after you opened it")
    var confirmed = edit
    confirmed["allowReconciled"] = .bool(true)
    _ = try await engine.call("saveTransaction", arguments: confirmed)
    current = try await snapshot(engine)
    let edited = current.transactions.first { $0.id == adjustment.id }
    precondition(edited?.notes == "Confirmed edit" && edited?.isReconciled == true && edited?.cleared == true,
                  "A reconciled transaction must stay cleared and locked when edited")

    // Moving a reconciled transaction to another account unlocks it, as in Actual's desktop editor.
    var moved = confirmed
    moved["accountId"] = .string(other.id)
    _ = try await engine.call("saveTransaction", arguments: moved)
    let movedFlags = try flags(adjustment.id).first
    precondition(movedFlags?.reconciled == false && movedFlags?.cleared == true)
    moved["accountId"] = id
    _ = try await engine.call("saveTransaction", arguments: moved)

    // Unlocking a split unlocks its children.
    let lockedSplit = try flags(split.id)
    precondition(lockedSplit.allSatisfy(\.reconciled))
    _ = try await engine.call("unlockTransaction", arguments: ["id": .string(split.id)])
    let unlockedSplit = try flags(split.id)
    precondition(unlockedSplit.allSatisfy { !$0.reconciled && $0.cleared })

    // Exiting an unbalanced reconciliation locks nothing but records the time, as Actual does.
    try await Task.sleep(for: .milliseconds(5))
    _ = try await engine.call("finishReconciliation", arguments: ["accountId": id, "targetBalance": .number(target + 1), "lock": .bool(false)])
    let afterExit = try flags(split.id)
    precondition(afterExit.allSatisfy { !$0.reconciled })
    let exited = try await snapshot(engine).accounts.first { $0.id == account.id }?.lastReconciledDate
    precondition(exited.map { $0 > reconciledAt } == true)

    guard let locked = try sql(
      "SELECT id FROM transactions WHERE acct = ? AND reconciled = 1 AND isParent = 0 AND isChild = 0 AND transferred_id IS NULL AND tombstone = 0 AND id != ? LIMIT 1",
      [account.id, adjustment.id]
    ).first?["id"] as? String else { throw EngineFailure("No reconciled transaction to delete") }
    _ = try await engine.call("deleteTransaction", arguments: ["id": .string(locked), "allowReconciled": .bool(true)])
    let afterDelete = try await snapshot(engine)
    precondition(!afterDelete.transactions.contains { $0.id == locked })
    print("PASS: reconciliation clears splits/transfers, adjusts, locks, unlocks, confirms reconciled edits")
  }
}
