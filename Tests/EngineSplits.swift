import Foundation

extension EngineSmoke {
  /// Creates, edits, unsplits, and deletes split transactions as Actual's mobile editor saves them.
  static func splits(data: URL, resources: URL) async throws {
    let engine = try EngineClient(dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    let budget = try await activeBudget(engine)
    func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) {
      precondition(condition, message(), line: line)
    }
    func save(_ arguments: [String: JSONValue]) async throws {
      _ = try await engine.call("saveSplit", arguments: arguments)
    }
    func expectFailure(_ arguments: [String: JSONValue], _ message: String, line: UInt = #line) async throws {
      var failed = false
      do { try await save(arguments) } catch {
        failed = true
        check(error.localizedDescription.contains(message), "Unexpected error: \(error.localizedDescription)", line: line)
      }
      check(failed, "saveSplit should have failed", line: line)
    }
    func find(_ id: String) async throws -> Transaction? {
      try await engine.call("register", as: [Transaction].self).first { $0.id == id }
    }
    func part(_ amount: Int, _ category: String, _ notes: String = "", id: String? = nil) -> JSONValue {
      var fields: [String: JSONValue] = [
        "amount": .number(amount), "categoryId": .string(category), "notes": .string(notes),
      ]
      if let id { fields["id"] = .string(id) }
      return .object(fields)
    }
    func rows(_ id: String) throws -> [[String: Any]] {
      try query(data: data, resources: resources, budget: budget,
                "SELECT id, amount, category, isParent, isChild, parent_id, acct, date, tombstone FROM transactions WHERE (id = ? OR parent_id = ?) AND tombstone = 0",
                [id, id])
    }

    let overview = try await engine.call("overview", as: BudgetOverview.self)
    guard let account = overview.openAccounts.first(where: { !$0.offbudget }),
          let other = overview.openAccounts.first(where: { !$0.offbudget && $0.id != account.id })
    else { throw EngineFailure("Demo fixture needs two on-budget accounts") }
    let expenses = try await snapshot(engine, month: BudgetDate.month(Date())).categories.filter { !$0.isIncome }
    let (food, fun, extra) = (expenses[0].id, expenses[1].id, expenses[2].id)
    let id = UUID().uuidString.lowercased()
    let base: [String: JSONValue] = [
      "newId": .string(id), "accountId": .string(account.id), "date": .string("2026-09-21"),
      "payeeName": .string("Split Market"), "notes": .string("weekly shop"), "cleared": .bool(false),
      "amount": .number(-10_000),
    ]

    // Parts must add up to the total.
    var unbalanced = base
    unbalanced["splits"] = .array([part(-6_000, food), part(-3_000, fun)])
    try await expectFailure(unbalanced, "must add up")
    check(try rows(id).isEmpty, "An unbalanced split must not be saved")

    var created = base
    created["splits"] = .array([part(-6_000, food, "groceries"), part(-4_000, fun, "treats")])
    try await save(created)
    guard var split = try await find(id) else { throw EngineFailure("Split missing") }
    check(split.isParent && split.amount == -10_000 && split.title == "Split Market")
    check(split.splits?.map(\.amount) == [-6_000, -4_000], "\(String(describing: split.splits))")
    check(split.splits?.map(\.categoryId) == [food, fun] && split.splits?.first?.notes == "groceries")
    var stored = try rows(id)
    check(stored.count == 3 && stored.filter { ($0["isChild"] as? Int) == 1 }.allSatisfy { $0["acct"] as? String == account.id })

    // Edit: change a part, add one, move the whole split to another account and date.
    let first = split.splits![0].id, second = split.splits![1].id
    var edited = base
    edited.removeValue(forKey: "newId")
    edited["id"] = .string(id)
    edited["accountId"] = .string(other.id)
    edited["date"] = .string("2026-09-22")
    edited["amount"] = .number(-12_000)
    edited["splits"] = .array([part(-5_000, food, "groceries", id: first), part(-4_000, fun, "treats", id: second),
                               part(-3_000, extra, "household")])
    try await save(edited)
    split = try await find(id)!
    check(split.accountId == other.id && split.date == "2026-09-22" && split.amount == -12_000)
    check(split.splits?.map(\.amount) == [-5_000, -4_000, -3_000] && split.splits?.first?.id == first)
    stored = try rows(id)
    check(stored.filter { ($0["isChild"] as? Int) == 1 }.allSatisfy { $0["acct"] as? String == other.id })

    // Removing a part deletes it; unknown parts are rejected.
    edited["amount"] = .number(-9_000)
    edited["splits"] = .array([part(-5_000, food, id: first), part(-4_000, fun, id: second)])
    try await save(edited)
    check(try await find(id)?.splits?.count == 2 && (try rows(id)).count == 3)
    var stale = edited
    stale["splits"] = .array([part(-9_000, food, id: UUID().uuidString.lowercased())])
    try await expectFailure(stale, "no longer exists")

    // Without parts, it becomes an ordinary transaction again.
    var single = edited
    single["splits"] = .array([])
    single["categoryId"] = .string(extra)
    try await save(single)
    let plain = try await find(id)
    check(plain?.isParent == false && plain?.categoryId == extra && plain?.splits == nil)
    check(try rows(id).count == 1)

    // Parts with their own payee, and a part that transfers to another account, as in Actual.
    let transferID = UUID().uuidString.lowercased()
    var withTransfer = base
    withTransfer["newId"] = .string(transferID)
    var transferPart = part(-2_500, food, "to savings")
    if case .object(var fields) = transferPart {
      fields["transferAccountId"] = .string(other.id)
      transferPart = .object(fields)
    }
    var ownPayee = part(-7_500, fun, "snacks")
    if case .object(var fields) = ownPayee {
      fields["payeeName"] = .string("Native Snack Bar")
      ownPayee = .object(fields)
    }
    withTransfer["splits"] = .array([ownPayee, transferPart])
    try await save(withTransfer)
    guard let transferSplit = try await find(transferID), let parts = transferSplit.splits, parts.count == 2
    else { throw EngineFailure("Transfer split missing") }
    check(transferSplit.canEdit, "A split with a transfer part can be edited")
    check(parts[0].payeeName == "Native Snack Bar" && parts[0].transferAccountId == nil)
    check(parts[1].transferAccountId == other.id && parts[1].isTransfer && parts[1].categoryId == nil,
          "A transfer between on-budget accounts has no category: \(parts[1])")
    func linked() async throws -> Transaction? {
      try await engine.call("register", as: [Transaction].self)
        .first { $0.accountId == other.id && $0.transferAccountId == account.id && $0.notes == "to savings" }
    }
    check(try await linked()?.amount == 2_500, "The transfer part adds its other side")
    check(try await linked()?.transferInSplit == true)
    // Changing the transfer part updates its other side; removing it removes that too.
    var retargeted = withTransfer
    retargeted.removeValue(forKey: "newId")
    retargeted["id"] = .string(transferID)
    var movedPart = part(-3_000, food, "to savings", id: parts[1].id)
    if case .object(var fields) = movedPart {
      fields["transferAccountId"] = .string(other.id)
      movedPart = .object(fields)
    }
    var keptPayee = part(-7_000, fun, "snacks", id: parts[0].id)
    if case .object(var fields) = keptPayee {
      fields["payeeId"] = parts[0].payeeId.map { .string($0) } ?? .null
      keptPayee = .object(fields)
    }
    retargeted["splits"] = .array([keptPayee, movedPart])
    try await save(retargeted)
    check(try await linked()?.amount == 3_000, "The other side follows the part's amount")
    check(try await find(transferID)?.splits?[0].payeeName == "Native Snack Bar", "A part keeps its own payee")
    retargeted["splits"] = .array([part(-10_000, fun, "snacks", id: parts[0].id)])
    try await save(retargeted)
    check(try await linked() == nil, "Removing the transfer part removes its other side")
    _ = try await engine.call("deleteTransaction", arguments: ["id": .string(transferID)])

    // An ordinary transaction can be split, and a split deleted with its parts.
    try await save(edited.merging(["splits": .array([part(-5_000, food), part(-4_000, fun)])]) { $1 })
    check(try await find(id)?.splits?.count == 2)
    _ = try await engine.call("deleteTransaction", arguments: ["id": .string(id)])
    check(try await find(id) == nil && (try rows(id)).isEmpty)
    print("PASS: split transactions create, validate, edit, unsplit, split again, and delete")
  }
}
