import Foundation

@main struct EngineRecovery {
  static let resources = URL(fileURLWithPath: CommandLine.arguments[1])
  static func main() async throws {
    let data = FileManager.default.temporaryDirectory.appendingPathComponent(
      "native-review-resolution-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: data) }
    try cleanupProbe(data: data.appendingPathComponent("cleanup"))
    let budgetData = data.appendingPathComponent("budget")
    try await createFixture(data: budgetData)
    try injectPending(data: budgetData)
    try await verifyWarning(data: budgetData)
    try await verifyWarning(data: budgetData)
    print(
      "PASS: discarded replay warning remains visible and blocks writes across fresh engine lifetimes"
    )
    try await verifyAcknowledgement(data: budgetData)
  }
  /// After review, the user may keep using the budget, as Actual allows.
  /// Changes waiting for a newer app version stay blocked.
  static func verifyAcknowledgement(data: URL) async throws {
    let engine = try EngineClient(
      dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    _ = try await engine.call("bootstrap")
    _ = try await engine.call("acknowledgeSyncWarning")
    let cleared = try await BudgetSnapshot.load(engine, month: "2026-09")
    precondition(cleared.syncWarning == nil)
    guard let account = cleared.openAccounts.first else { throw EngineFailure("No demo account") }
    _ = try await engine.call(
      "saveTransaction",
      arguments: [
        "accountId": .string(account.id), "date": .string("2026-09-17"),
        "amount": .number(-100), "notes": .string("After review"),
      ])
    let settings =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: data.appendingPathComponent("settings.json"))) as! [String: Any]
    let budgetId = settings["native-last-budget"] as! String
    precondition(settings["native-dropped-sync:\(budgetId)"] == nil)
    _ = try await engine.call("close")

    // A change for a table this version does not have waits for an update.
    let host = try NativeHost(dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    let id = try host.perform("sql.open", ["path": "/documents/\(budgetId)/db.sqlite"]) as! Int
    _ = try host.perform(
      "sql.query",
      [
        "id": id,
        "sql":
          "INSERT INTO messages_pending (timestamp,dataset,row,column,value) VALUES (?, ?, ?, ?, ?)",
        "params": [
          "2026-09-18T00:00:00.000Z-0000-0000000000000000", "future_table", "row1", "value", "N:1",
        ],
      ])
    _ = try host.perform("sql.close", ["id": id])
    _ = try await engine.call("open", arguments: ["id": .string(budgetId)])
    let newer = try await engine.call("overview", as: BudgetOverview.self)
    precondition(newer.syncWarning?.kind == .newerVersion, "Expected a newer-version warning")
    for method in ["acknowledgeSyncWarning", "saveTransaction"] {
      do {
        _ = try await engine.call(method)
        throw EngineFailure("\(method) was allowed with newer-version changes")
      } catch {
        precondition(!error.localizedDescription.contains("was allowed"), error.localizedDescription)
      }
    }
    print("PASS: a reviewed discard warning can be dismissed; newer-version changes stay blocked")
  }
  static func cleanupProbe(data: URL) throws {
    let raw = try Data(contentsOf: resources.appendingPathComponent("default-db.sqlite"))
      .base64EncodedString()
    do {
      let host = try NativeHost(
        dataDirectory: data, resourceDirectory: resources, useKeychain: false)
      let id = try host.perform("sql.open", ["data": raw]) as! Int
      let openedFiles = try FileManager.default.contentsOfDirectory(atPath: data.path)
      precondition(openedFiles.contains(where: { $0.hasPrefix(".import-") }))
      _ = try host.perform("sql.close", ["id": id])
      let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: data.path)
      precondition(remainingFiles.isEmpty)
      _ = try host.perform("sql.open", ["data": raw])
    }
    let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: data.path)
    precondition(remainingFiles.isEmpty)
    print("PASS: buffer database files removed on close and host deinitialization")
  }
  static func createFixture(data: URL) async throws {
    let engine = try EngineClient(
      dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    _ = try await engine.call("demo")
  }
  static func injectPending(data: URL) throws {
    let host = try NativeHost(dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    var settings = try host.perform("settings.read", [:]) as! [String: Any]
    let budgetId = settings["native-last-budget"] as! String
    settings["server-url"] = "http://127.0.0.1:1"
    _ = try host.perform("settings.write", settings)
    let id = try host.perform("sql.open", ["path": "/documents/\(budgetId)/db.sqlite"]) as! Int
    _ = try host.perform(
      "sql.exec",
      [
        "id": id,
        "sql":
          "CREATE TABLE review_constraint (id TEXT PRIMARY KEY, value INTEGER CHECK(value > 0)); CREATE TABLE IF NOT EXISTS messages_pending (timestamp TEXT, dataset TEXT, row TEXT, column TEXT, value TEXT, UNIQUE(dataset,row,column));",
      ])
    _ = try host.perform(
      "sql.query",
      [
        "id": id,
        "sql":
          "INSERT INTO messages_pending (timestamp,dataset,row,column,value) VALUES (?, ?, ?, ?, ?)",
        "params": [
          "2026-09-17T00:00:00.000Z-0000-0000000000000000", "review_constraint", "row1", "value",
          "N:-1",
        ],
      ])
    _ = try host.perform("sql.close", ["id": id])
  }
  static func verifyWarning(data: URL) async throws {
    let engine = try EngineClient(
      dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    _ = try await engine.call("bootstrap")
    let snapshot = try await BudgetSnapshot.load(engine, month: "2026-09")
    guard snapshot.syncWarning?.contains("could not be applied") == true else {
      throw EngineFailure("Unexpected warning: \(snapshot.syncWarning ?? "nil")")
    }
    for method in [
      "saveTransaction", "setCleared", "unlockTransaction", "createReconciliationTransaction",
      "finishReconciliation",
    ] {
      var blocked = false
      do { _ = try await engine.call(method) } catch {
        blocked = error.localizedDescription.contains("could not be applied")
      }
      precondition(blocked, "\(method) was not blocked")
    }
    let settings =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: data.appendingPathComponent("settings.json"))) as! [String: Any]
    let budgetId = settings["native-last-budget"] as! String
    precondition(settings["native-dropped-sync:\(budgetId)"] as? Bool == true)
  }
}
