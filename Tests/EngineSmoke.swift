import Foundation

@main struct EngineSmoke {
  static func snapshot(_ engine: EngineClient) async throws -> BudgetSnapshot {
    try JSONDecoder().decode(
      BudgetSnapshot.self,
      from: await engine.call("snapshot", arguments: ["month": .string("2026-09")]))
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
