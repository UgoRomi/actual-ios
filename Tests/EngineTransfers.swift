import Foundation

extension EngineSmoke {
  /// Makes, edits, and deletes transfers the way Actual's mobile editor does.
  static func transfers(data: URL, resources: URL) async throws {
    let engine = try EngineClient(
      dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    let budget = try await activeBudget(engine)
    func sql(_ statement: String, _ params: [Any] = []) throws -> [[String: Any]] {
      try query(data: data, resources: resources, budget: budget, statement, params)
    }
    func expectFailure(_ method: String, _ arguments: [String: JSONValue], _ message: String) async throws {
      var failed = false
      do { _ = try await engine.call(method, arguments: arguments) } catch {
        failed = true
        precondition(error.localizedDescription.contains(message), "Unexpected error: \(error.localizedDescription)")
      }
      precondition(failed, "\(method) should have failed")
    }

    let start = try await snapshot(engine)
    let onBudget = start.openAccounts.filter { !$0.offbudget }
    guard onBudget.count > 1, let offBudget = start.openAccounts.first(where: \.offbudget),
      let category = start.categories.first(where: { !$0.isIncome })
    else { throw EngineFailure("Demo fixture has no accounts or category for transfers") }
    let (from, to) = (onBudget[0], onBudget[1])
    var current = start
    func row(_ id: String) -> Transaction? { current.transactions.first { $0.id == id } }
    func balance(_ account: Account) -> Int? { current.accounts.first { $0.id == account.id }?.balance }
    func save(_ arguments: [String: JSONValue]) async throws {
      _ = try await engine.call("saveTransaction", arguments: arguments)
      current = try await snapshot(engine)
    }
    func transfer(_ id: String? = nil, account: Account, to other: Account, amount: Int, notes: String,
                  date: String = "2026-09-21", categoryId: String? = nil, cleared: Bool = false) -> [String: JSONValue] {
      var arguments: [String: JSONValue] = [
        "accountId": .string(account.id), "date": .string(date), "transferAccountId": .string(other.id),
        "categoryId": categoryId.map(JSONValue.string) ?? .null, "amount": .number(amount),
        "notes": .string(notes), "cleared": .bool(cleared),
      ]
      if let id { arguments["id"] = .string(id) }
      return arguments
    }

    // Other accounts are offered for transfers; their payees are not listed as payees.
    let transferPayees = Set(try sql("SELECT id FROM payees WHERE transfer_acct IS NOT NULL").compactMap { $0["id"] as? String })
    precondition(!transferPayees.isEmpty && !start.payees.contains { transferPayees.contains($0.id) })

    // A new transfer adds its linked transaction. Between on-budget accounts, the category is dropped.
    try await save(transfer(account: from, to: to, amount: -5000, notes: "Native transfer", categoryId: category.id))
    guard let sent = current.transactions.first(where: { $0.accountId == from.id && $0.notes == "Native transfer" }),
      let receivedId = sent.transferId, let received = row(receivedId)
    else { throw EngineFailure("Transfer or its linked transaction missing") }
    precondition(sent.transferAccountId == to.id && sent.amount == -5000 && sent.categoryId == nil && sent.canEdit)
    precondition(sent.title == "Transfer to \(to.name)" && sent.detail == "Transfer")
    precondition(received.accountId == to.id && received.amount == 5000 && received.transferId == sent.id)
    precondition(received.transferAccountId == from.id && received.title == "Transfer from \(from.name)")
    precondition(received.notes == "Native transfer" && received.date == sent.date && !received.cleared)
    precondition(balance(from) == from.balance - 5000 && balance(to) == to.balance + 5000)

    // Edits from the other side carry the amount and notes over, but not the date or cleared state, as in Actual.
    try await save(transfer(received.id, account: to, to: from, amount: 6000, notes: "Edited transfer",
                            date: "2026-09-22", cleared: true))
    precondition(row(sent.id)?.amount == -6000 && row(sent.id)?.notes == "Edited transfer")
    precondition(row(sent.id)?.date == "2026-09-21" && row(sent.id)?.cleared == false)
    precondition(row(received.id)?.date == "2026-09-22" && row(received.id)?.cleared == true)
    precondition(balance(from) == from.balance - 6000 && balance(to) == to.balance + 6000)

    // Choosing an off-budget account moves the linked transaction there, and the category stays.
    try await save(transfer(sent.id, account: from, to: offBudget, amount: -6000, notes: "Edited transfer",
                            categoryId: category.id))
    precondition(row(sent.id)?.transferAccountId == offBudget.id && row(sent.id)?.transferId == received.id)
    precondition(row(sent.id)?.categoryId == category.id && row(sent.id)?.detail == category.name)
    precondition(row(received.id)?.accountId == offBudget.id && row(received.id)?.amount == 6000)
    precondition(row(received.id)?.transferAccountId == from.id)
    precondition(balance(to) == to.balance && balance(offBudget) == offBudget.balance + 6000)

    // An ordinary payee removes the linked transaction; another account adds one again.
    try await save([
      "id": .string(sent.id), "accountId": .string(from.id), "date": .string("2026-09-21"),
      "payeeName": .string("Native transfer payee"), "categoryId": .string(category.id),
      "amount": .number(-6000), "notes": .string("Edited transfer"), "cleared": .bool(false),
    ])
    precondition(row(sent.id)?.transferId == nil && row(sent.id)?.transferAccountId == nil && row(received.id) == nil)
    precondition(row(sent.id)?.title == "Native transfer payee" && balance(offBudget) == offBudget.balance)
    try await save(transfer(sent.id, account: from, to: to, amount: -6000, notes: "Edited transfer", categoryId: category.id))
    guard let linkedId = row(sent.id)?.transferId, let linked = row(linkedId)
    else { throw EngineFailure("Transfer was not linked again") }
    precondition(linked.accountId == to.id && linked.amount == 6000 && row(sent.id)?.categoryId == nil)

    // A transfer needs two different accounts, including when a side moves.
    try await expectFailure("saveTransaction", transfer(account: to, to: to, amount: -1, notes: "Same account"),
                            "two different accounts")
    try await expectFailure("saveTransaction", transfer(sent.id, account: to, to: to, amount: -6000, notes: "Moved"),
                            "two different accounts")
    precondition(row(sent.id)?.accountId == from.id)

    // A reconciled linked transaction needs its own confirmation, checked when saving.
    _ = try await engine.call("setCleared", arguments: ["id": .string(linkedId), "cleared": .bool(true)])
    current = try await snapshot(engine)
    let clearedBalance = current.accounts.first { $0.id == to.id }?.clearedBalance ?? 0
    _ = try await engine.call(
      "finishReconciliation",
      arguments: ["accountId": .string(to.id), "targetBalance": .number(clearedBalance), "lock": .bool(true)])
    current = try await snapshot(engine)
    precondition(row(sent.id)?.transferReconciled == true && row(sent.id)?.isReconciled == false)
    precondition(row(linkedId)?.isReconciled == true)
    var edit = transfer(sent.id, account: from, to: to, amount: -7000, notes: "Reconciled link")
    try await expectFailure("saveTransaction", edit, "reconciled after you opened this transfer")
    // Confirming this side does not cover the other one.
    edit["allowReconciled"] = .bool(true)
    try await expectFailure("saveTransaction", edit, "reconciled after you opened this transfer")
    try await expectFailure("deleteTransaction", ["id": .string(sent.id), "allowReconciled": .bool(true)],
                            "reconciled after you opened this transfer")
    precondition(row(linkedId)?.amount == 6000)
    edit["allowReconciledTransfer"] = .bool(true)
    try await save(edit)
    precondition(row(linkedId)?.amount == 7000 && row(linkedId)?.notes == "Reconciled link")
    precondition(row(linkedId)?.isReconciled == true, "Actual keeps the linked transaction locked")

    // Deleting a transfer deletes both sides.
    _ = try await engine.call(
      "deleteTransaction", arguments: ["id": .string(sent.id), "allowReconciledTransfer": .bool(true)])
    current = try await snapshot(engine)
    precondition(row(sent.id) == nil && row(linkedId) == nil)
    precondition(balance(from) == from.balance && balance(to) == to.balance && balance(offBudget) == offBudget.balance)

    // A transfer linked to part of a split stays view only: Actual would unbalance the split.
    _ = try await engine.call("close")
    guard let fromPayee = try sql("SELECT id FROM payees WHERE transfer_acct = ?", [from.id]).first?["id"] as? String,
      let toPayee = try sql("SELECT id FROM payees WHERE transfer_acct = ?", [to.id]).first?["id"] as? String
    else { throw EngineFailure("Transfer payees missing") }
    let insert = """
      INSERT INTO transactions (id, isParent, isChild, parent_id, acct, amount, description, notes, date,
        transferred_id, sort_order, cleared, reconciled, tombstone)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, 20260923, ?, 1, 0, 0, 0)
      """
    _ = try sql(insert, ["native-split", 1, 0, NSNull(), from.id, -3000, NSNull(), "Split transfer", NSNull()])
    _ = try sql(insert, ["native-split-child", 0, 1, "native-split", from.id, -3000, toPayee, "Split transfer", "native-split-other"])
    _ = try sql(insert, ["native-split-other", 0, 0, NSNull(), to.id, 3000, fromPayee, "Split transfer", "native-split-child"])
    _ = try await engine.call("open", arguments: ["id": .string(budget)])
    current = try await snapshot(engine)
    guard let splitLinked = row("native-split-other") else { throw EngineFailure("Split-linked transfer missing") }
    precondition(splitLinked.transferInSplit == true && !splitLinked.canEdit && splitLinked.isTransfer)
    try await expectFailure("saveTransaction", transfer("native-split-other", account: to, to: from, amount: 4000,
                                                        notes: "Split transfer"), "part of a split")
    try await expectFailure("deleteTransaction", ["id": .string("native-split-other")], "part of a split")
    precondition(row("native-split-other")?.amount == 3000)
    _ = try await engine.call("setCleared", arguments: ["id": .string("native-split-other"), "cleared": .bool(true)])
    let clearedSide = try sql("SELECT cleared FROM transactions WHERE id = 'native-split-other'").first?["cleared"] as? Int64
    precondition(clearedSide == 1, "Split-linked transfers can still be cleared while reconciling")
    print("PASS: transfers create, edit from either side, retarget, unlink, relink, confirm reconciled links, delete both sides")
  }
}
