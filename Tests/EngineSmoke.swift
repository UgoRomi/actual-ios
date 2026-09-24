import Foundation

@main struct EngineSmoke {
  static func snapshot(_ engine: EngineClient, month: String = "2026-09") async throws
    -> BudgetSnapshot
  {
    try JSONDecoder().decode(
      BudgetSnapshot.self,
      from: await engine.call("snapshot", arguments: ["month": .string(month)]))
  }
  static func expenseBudgeted(_ snapshot: BudgetSnapshot) -> Int {
    snapshot.categories.filter { !$0.isIncome }.reduce(0) { $0 + $1.budgeted }
  }
  /// Reads the budget database through a separate connection, as a second process would.
  static func query(data: URL, resources: URL, budget: String, _ sql: String, _ params: [Any] = [])
    throws -> [[String: Any]]
  {
    let host = try NativeHost(dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    guard let db = try host.perform("sql.open", ["path": "/documents/\(budget)/db.sqlite"]) as? Int
    else { throw EngineFailure("Budget database did not open") }
    defer { _ = try? host.perform("sql.close", ["id": db]) }
    return try host.perform(
      "sql.query", ["id": db, "sql": sql, "params": params, "fetchAll": true]) as? [[String: Any]]
      ?? []
  }
  static func activeBudget(_ engine: EngineClient) async throws -> String {
    guard
      let id = try JSONDecoder().decode(Bootstrap.self, from: await engine.call("bootstrap"))
        .activeBudgetId
    else { throw EngineFailure("No active budget") }
    return id
  }
  static func main() async throws {
    let resources = URL(fileURLWithPath: CommandLine.arguments[1])
    let data = FileManager.default.temporaryDirectory.appendingPathComponent(
      "actual-native-smoke-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: data) }
    try hostTests(data: data.appendingPathComponent("host"), resources: resources)
    let saved = try await createAndEdit(
      data: data.appendingPathComponent("budget"), resources: resources)
    let restarted = try EngineClient(
      dataDirectory: data.appendingPathComponent("budget"), resourceDirectory: resources,
      useKeychain: false)
    _ = try await restarted.call("bootstrap")
    let restored = try await snapshot(restarted)
    guard let transaction = restored.transactions.first(where: { $0.id == saved.id }) else {
      throw EngineFailure("Saved transaction missing after restart")
    }
    precondition(transaction.amount == -2345)
    precondition(transaction.notes == "edited offline")
    precondition(
      restored.accounts.first(where: { $0.id == saved.account })?.balance == saved.balance)
    precondition(restored.categories.first(where: { $0.id == saved.category })?.budgeted == 45678)
    _ = try await restarted.call("deleteTransaction", arguments: ["id": .string(saved.id)])
    let deleted = try await snapshot(restarted)
    precondition(!deleted.transactions.contains(where: { $0.id == saved.id }))
    try await trackingBudget(data: data.appendingPathComponent("budget"), resources: resources)
    print(
      "PASS: actual engine demo, add, edit, budget allocation, offline reopen, exact balances, delete"
    )
  }
  static func createAndEdit(data: URL, resources: URL) async throws -> (
    id: String, account: String, balance: Int, category: String
  ) {
    let engine = try EngineClient(
      dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    _ = try await engine.call("bootstrap")
    _ = try await engine.call("demo")
    let before = try await snapshot(engine)
    precondition(before.budgetType == .envelope && before.toBudget != nil && before.saved == nil)
    precondition(before.totalBudgeted == expenseBudgeted(before))
    guard let account = before.openAccounts.first(where: { !$0.offbudget }),
      let category = before.categories.first(where: { !$0.isIncome })
    else { throw EngineFailure("Demo fixture has no usable account/category") }
    _ = try await engine.call(
      "saveTransaction",
      arguments: [
        "accountId": .string(account.id), "date": .string("2026-09-17"),
        "payeeName": .string("Native smoke merchant"), "categoryId": .string(category.id),
        "amount": .number(-1234), "notes": .string("offline"), "cleared": .bool(false),
      ])
    let added = try await snapshot(engine)
    guard let transaction = added.transactions.first(where: { $0.title == "Native smoke merchant" })
    else { throw EngineFailure("Added transaction not found") }
    precondition(transaction.amount == -1234)
    precondition(transaction.categoryName == category.name)
    precondition(
      added.accounts.first(where: { $0.id == account.id })?.balance == account.balance - 1234)
    _ = try await engine.call(
      "saveTransaction",
      arguments: [
        "id": .string(transaction.id), "accountId": .string(account.id),
        "date": .string("2026-09-17"), "payeeId": .string(transaction.payeeId ?? ""),
        "categoryId": .string(category.id), "amount": .number(-2345),
        "notes": .string("edited offline"), "cleared": .bool(true),
      ])
    _ = try await engine.call(
      "budget",
      arguments: [
        "month": .string("2026-09"), "categoryId": .string(category.id), "amount": .number(45678),
      ])
    let edited = try await snapshot(engine)
    precondition(edited.transactions.first(where: { $0.id == transaction.id })?.amount == -2345)
    if let transfer = edited.transactions.first(where: { $0.isTransfer }) {
      do {
        _ = try await engine.call("deleteTransaction", arguments: ["id": .string(transfer.id)])
        throw EngineFailure("Transfer deletion should be rejected")
      } catch {
        precondition(error.localizedDescription.contains("split transactions and transfers"))
      }
    }
    return (transaction.id, account.id, account.balance - 2345, category.id)
  }
  static func trackingBudget(data: URL, resources: URL) async throws {
    let engine = try EngineClient(
      dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    let budget = try await activeBudget(engine)
    _ = try await engine.call("close")
    // Actual reads budgetType when a budget loads; the separate cache is rebuilt.
    _ = try query(
      data: data, resources: resources, budget: budget,
      "INSERT OR REPLACE INTO preferences (id, value) VALUES ('budgetType', 'tracking')")
    try? FileManager.default.removeItem(
      at: data.appendingPathComponent(budget).appendingPathComponent("cache.sqlite"))
    _ = try await engine.call("open", arguments: ["id": .string(budget)])
    let projected = try await snapshot(engine, month: BudgetDate.month(Date()))
    precondition(projected.budgetType == .tracking && projected.toBudget == nil)
    precondition(projected.savedIsProjected && projected.saved != nil)
    let incomeBudgeted = projected.categories.filter(\.isIncome).reduce(0) { $0 + $1.budgeted }
    precondition(projected.totalBudgeted == expenseBudgeted(projected))
    precondition(projected.saved == incomeBudgeted - projected.totalBudgeted)
    let lastMonth = Calendar(identifier: .gregorian).date(byAdding: .month, value: -1, to: Date())!
    let past = try await snapshot(engine, month: BudgetDate.month(lastMonth))
    precondition(past.budgetType == .tracking && !past.savedIsProjected && past.saved != nil)
    _ = try await engine.call("close")
    _ = try query(
      data: data, resources: resources, budget: budget,
      "DELETE FROM preferences WHERE id = 'budgetType'")
    try? FileManager.default.removeItem(
      at: data.appendingPathComponent(budget).appendingPathComponent("cache.sqlite"))
    _ = try await engine.call("open", arguments: ["id": .string(budget)])
    print("PASS: tracking budget summary, positive budgeted total, projected and actual savings")
  }
  static func hostTests(data: URL, resources: URL) throws {
    let host = try NativeHost(dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    guard let id = try host.perform("sql.open", ["path": ":memory:"]) as? Int else {
      throw EngineFailure("No sqlite handle")
    }
    _ = try host.perform(
      "sql.exec", ["id": id, "sql": "CREATE TABLE t (text TEXT, amount INTEGER); BEGIN;"])
    _ = try host.perform(
      "sql.query",
      [
        "id": id, "sql": "INSERT INTO t VALUES (?, ?)",
        "params": ["O'Brien €", 9_007_199_254_740_991],
      ])
    let rows =
      try host.perform("sql.query", ["id": id, "sql": "SELECT * FROM t", "fetchAll": true])
      as? [[String: Any]]
    precondition(rows?.first?["text"] as? String == "O'Brien €")
    precondition(rows?.first?["amount"] as? Int64 == 9_007_199_254_740_991)
    _ = try host.perform("sql.exec", ["id": id, "sql": "ROLLBACK"])
    let empty =
      try host.perform("sql.query", ["id": id, "sql": "SELECT * FROM t", "fetchAll": true])
      as? [[String: Any]]
    precondition(empty?.isEmpty == true)
    guard let exported = try host.perform("sql.export", ["id": id]) as? String,
      let imported = try host.perform("sql.open", ["data": exported]) as? Int
    else { throw EngineFailure("Import test setup failed") }
    let whileOpen = try FileManager.default.contentsOfDirectory(atPath: data.path)
    precondition(whileOpen.contains(where: { $0.hasPrefix(".import-") }))
    _ = try host.perform("sql.close", ["id": imported])
    let afterClose = try FileManager.default.contentsOfDirectory(atPath: data.path)
    precondition(!afterClose.contains(where: { $0.hasPrefix(".import-") }))
    _ = try host.perform("sql.close", ["id": id])
    let derived =
      try host.perform("crypto.derive", ["secret": "testing", "salt": "salt"]) as? String
    precondition(derived == "Tlsfx3doWeBn/zpD8+5IK8jSxnEKF8s5JITe8aDik1E=")
    let cleartext = Data("Encrypted Actual budget 🟣".utf8).base64EncodedString()
    guard let derived,
      let sealed = try host.perform("crypto.encrypt", ["key": derived, "data": cleartext])
        as? [String: String]
    else { throw EngineFailure("Encryption failed") }
    let plain =
      try host.perform(
        "crypto.decrypt",
        [
          "key": derived, "data": sealed["value"]!, "iv": sealed["iv"]!,
          "authTag": sealed["authTag"]!,
        ]) as? String
    precondition(plain == cleartext)
    do {
      _ = try host.resolve("/documents/../../outside", writing: true)
      throw EngineFailure("Path escape accepted")
    } catch { precondition(error.localizedDescription.contains("Invalid file path")) }
    print(
      "PASS: native SQLite parameters/rollback/exact integers, PBKDF2 compatibility, AES-GCM, sandbox path rejection"
    )
  }
}
