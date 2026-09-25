import Foundation

extension EngineSmoke {
  /// Deletes budgets saved on this device, as Actual's "Delete file locally" does.
  static func budgetDeletion(data: URL, resources: URL) async throws {
    let setup = try EngineClient(
      dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    _ = try await setup.call("bootstrap")
    _ = try await setup.call("demo")
    _ = try await setup.call("close")
    // Actual hides its demo from the budget list. List two copies of it.
    let demo = data.appendingPathComponent("_demo-budget")
    for id in ["Local-Kept", "Local-Deleted"] {
      let copy = data.appendingPathComponent(id)
      try FileManager.default.copyItem(at: demo, to: copy)
      let metadataURL = copy.appendingPathComponent("metadata.json")
      var metadata =
        try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as! [String: Any]
      metadata["id"] = id
      metadata["budgetName"] = id
      try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
    }
    let settingsURL = data.appendingPathComponent("settings.json")
    func settings() throws -> [String: Any] {
      try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
    }
    var saved = try settings()
    saved["native-last-budget"] = "Local-Deleted"
    saved["native-dropped-sync:Local-Deleted"] = true
    saved["native-dropped-sync:Local-Kept"] = true
    try JSONSerialization.data(withJSONObject: saved).write(to: settingsURL)

    let engine = try EngineClient(
      dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    let started = try await engine.call("bootstrap", as: Bootstrap.self)
    precondition(started.activeBudgetId == "Local-Deleted")
    precondition(Set(started.budgets.map(\.id)) == ["Local-Kept", "Local-Deleted"])

    var failed = false
    do {
      _ = try await engine.call("deleteBudget", arguments: ["id": .string("Local-Missing")])
    } catch {
      failed = true
      precondition(error.localizedDescription.contains("no longer on this device"))
    }
    precondition(failed, "Deleting a budget that is not on this device should fail")

    // The open budget closes first, and is not reopened on the next launch.
    let listing = try await engine.call(
      "deleteBudget", arguments: ["id": .string("Local-Deleted")], as: BudgetListing.self)
    precondition(listing.budgets.map(\.id) == ["Local-Kept"])
    precondition(
      !FileManager.default.fileExists(atPath: data.appendingPathComponent("Local-Deleted").path))
    let remaining = try settings()
    precondition(remaining["native-last-budget"] == nil)
    precondition(remaining["native-dropped-sync:Local-Deleted"] == nil)
    precondition(remaining["native-dropped-sync:Local-Kept"] as? Bool == true)
    let restarted = try await engine.call("bootstrap", as: Bootstrap.self)
    precondition(restarted.activeBudgetId == nil)
    precondition(restarted.budgets.map(\.id) == ["Local-Kept"])

    // Other budgets are untouched.
    _ = try await engine.call("open", arguments: ["id": .string("Local-Kept")])
    let kept = try await snapshot(engine)
    precondition(kept.budgetName == "Local-Kept" && !kept.accounts.isEmpty)
    print("PASS: local budget deletion closes it, removes its files and settings, keeps other budgets")
  }
}
