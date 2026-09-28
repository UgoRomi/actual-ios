import Foundation

extension EngineSmoke {
  /// Sets, previews, and applies category targets the way Actual's budget automations editor does.
  static func targets(data: URL, resources: URL) async throws {
    var engine = try EngineClient(
      dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    let budget = try await activeBudget(engine)
    let month = BudgetDate.month(Date())
    // Evaluates its condition first, so conditions may await.
    func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) {
      precondition(condition, message(), line: line)
    }
    func sql(_ statement: String, _ params: [Any] = []) throws -> [[String: Any]] {
      try query(data: data, resources: resources, budget: budget, statement, params)
    }
    func expectFailure(_ method: String, _ arguments: [String: JSONValue], _ message: String) async throws {
      var failed = false
      do { _ = try await engine.call(method, arguments: arguments) } catch {
        failed = true
        check(error.localizedDescription.contains(message), "Unexpected error: \(error.localizedDescription)")
      }
      check(failed, "\(method) should have failed")
    }
    func targets(_ id: String) async throws -> CategoryTargets {
      try await engine.call(
        "categoryTargets", arguments: ["categoryId": .string(id), "month": .string(month)],
        as: CategoryTargets.self)
    }
    func preview(_ id: String, _ templates: [TargetTemplate]) async throws -> TargetPreview {
      try await engine.call(
        "previewTargets",
        arguments: ["categoryId": .string(id), "month": .string(month), "templates": .array(templates.map(\.json))],
        as: TargetPreview.self)
    }
    func save(_ id: String, _ templates: [TargetTemplate]) async throws {
      _ = try await engine.call(
        "saveTargets", arguments: ["categoryId": .string(id), "templates": .array(templates.map(\.json))])
    }
    func apply(_ id: String? = nil, overwrite: Bool = false) async throws -> String {
      var arguments: [String: JSONValue] = ["month": .string(month), "overwrite": .bool(overwrite)]
      if let id { arguments["categoryId"] = .string(id) }
      return try await engine.call("applyTargets", arguments: arguments, as: TargetsApplied.self).message
    }
    func category(_ id: String) async throws -> BudgetCategory {
      guard let found = try await snapshot(engine, month: month).categories.first(where: { $0.id == id })
      else { throw EngineFailure("Category \(id) is missing") }
      return found
    }

    let expenses = try await snapshot(engine, month: month).categories.filter { !$0.isIncome }
    guard expenses.count >= 3 else { throw EngineFailure("Demo fixture needs three expense categories") }
    let (edited, noted, broken) = (expenses[0], expenses[1], expenses[2])

    // A category without targets reads as notes-based and empty.
    let empty = try await targets(edited.id)
    check(empty.source == .notes && empty.templates.isEmpty && empty.unsupported.isEmpty)

    // Previews project exact amounts and report the web editor's problems.
    var fixed = TargetTemplate(kind: .fixed)
    fixed.amount = 12_345
    let fixedPreview = try await preview(edited.id, [fixed])
    check(fixedPreview.budgeted == 12_345 && fixedPreview.perTemplate == [12_345], "\(fixedPreview)")
    check(fixedPreview.canSave)
    let refill = TargetTemplate(kind: .refill)
    check(try await preview(edited.id, [refill]).problems == ["Add a balance cap"])
    var share = TargetTemplate(kind: .percentage)
    share.set("percent", .number(60))
    let shares = try await preview(edited.id, [share, share])
    check(shares.conflicts.contains { $0.contains("120%") }, "\(shares.conflicts)")
    var fractional = share
    fractional.set("percent", .double(12.5))
    check(try await preview(edited.id, [fractional]).canSave)

    // Invalid targets are not saved; valid ones are stored in Actual's decimal format.
    try await expectFailure(
      "saveTargets", ["categoryId": .string(edited.id), "templates": .array([refill.json])], "Add a balance cap")
    var cap = TargetTemplate(kind: .limit)
    // Actual budgets no more than the cap less the carried-over balance; keep it out of the way.
    cap.amount = 10_000_000
    try await save(edited.id, [fixed, cap])
    guard let row = try sql("SELECT goal_def, template_settings FROM categories WHERE id = ?", [edited.id]).first,
      let goalDef = row["goal_def"] as? String,
      let stored = try JSONSerialization.jsonObject(with: Data(goalDef.utf8)) as? [[String: Any]]
    else { throw EngineFailure("Targets were not stored") }
    check((stored[0]["amount"] as? Double) == 123.45 && (stored[1]["amount"] as? Double) == 100_000, "\(stored)")
    check((row["template_settings"] as? String)?.contains("\"ui\"") == true)
    let reread = try await targets(edited.id)
    check(reread.source == .ui && reread.templates.map(\.amount) == [12_345, 10_000_000])
    check(reread.templates[1].summary(currency: "") .contains("hard cap"))
    check(try await category(edited.id).hasTargets)

    // Applying budgets the target and sets the goal the balance is compared with.
    // Like Actual, applying budgets no more than is available, so free this month's funds first.
    for expense in expenses {
      _ = try await engine.call(
        "budget", arguments: ["month": .string(month), "categoryId": .string(expense.id), "amount": .number(0)])
    }
    let available = try await snapshot(engine, month: month).toBudget ?? 0
    guard available >= 20_000 else { throw EngineFailure("Demo month has only \(available) to budget") }
    check(try await apply(edited.id) == "Applied targets to 1 category.")
    var applied = try await category(edited.id)
    check(applied.budgeted == 12_345 && applied.goal == 12_345 && !applied.longGoal, "\(applied)")
    check(applied.goalDifference == 0)
    var goal = TargetTemplate(kind: .goal)
    goal.amount = 100_000
    try await save(edited.id, [fixed, cap, goal])
    _ = try await apply(edited.id)
    applied = try await category(edited.id)
    check(applied.goal == 100_000 && applied.longGoal && applied.budgeted == 12_345, "\(applied)")
    check(applied.goalDifference == applied.balance - 100_000)
    // The Budget screen's Underfunded filter shows a long-term goal until the balance reaches it.
    let funding = try await snapshot(engine, month: month).budget
    let underfunded = funding.expenseGroups(.underfunded).flatMap(\.categories)
    check(underfunded.contains { $0.id == edited.id } == (applied.balance < 100_000), "\(applied)")
    check(underfunded.count == funding.count(.underfunded))
    check(underfunded.allSatisfy { ($0.goalDifference ?? 0) < 0 })

    // Notes targets are read without changing the category, as the web editor shows them.
    _ = try await engine.call("close")
    _ = try sql(
      "INSERT OR REPLACE INTO notes (id, note) VALUES (?, ?)",
      [noted.id, "Monthly bills\n#template 50\n#goal 300\n#cleanup source"])
    _ = try sql("INSERT OR REPLACE INTO notes (id, note) VALUES (?, ?)", [broken.id, "#template this is not a target"])
    engine = try EngineClient(dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    _ = try await engine.call("open", arguments: ["id": .string(budget)])
    let fromNotes = try await targets(noted.id)
    check(fromNotes.source == .notes && fromNotes.unsupported.isEmpty)
    check(fromNotes.noteLines == ["#template 50", "#goal 300", "#cleanup source"], "\(fromNotes.noteLines)")
    check(fromNotes.templates.map(\.type) == ["periodic", "goal"], "\(fromNotes.templates.map(\.type))")
    check(fromNotes.templates.map(\.amount) == [5_000, 30_000])
    check(fromNotes.templates[0].note == "Monthly bills")
    check(try sql("SELECT goal_def FROM categories WHERE id = ?", [noted.id]).first?["goal_def"] is NSNull)
    check(try await category(noted.id).hasTargets)
    let unreadable = try await targets(broken.id)
    check(unreadable.unsupported == ["#template this is not a target"] && unreadable.templates.isEmpty)
    check(unreadable.preview == nil)

    // Saving moves notes targets to the editor and keeps the notes themselves.
    try await save(noted.id, fromNotes.templates)
    check(try await targets(noted.id).source == .ui)
    check(
      (try sql("SELECT note FROM notes WHERE id = ?", [noted.id]).first?["note"] as? String)?.contains("#template 50") == true)

    // Overwriting budgets every category with targets. Like Actual, it skips unreadable notes lines.
    check(try await apply(overwrite: true).hasPrefix("Applied targets"))
    check(try await category(noted.id).budgeted == 5_000)
    // Without overwrite, categories that already have a budget are left alone.
    _ = try await engine.call(
      "budget", arguments: ["month": .string(month), "categoryId": .string(noted.id), "amount": .number(777)])
    _ = try await apply()
    check(try await category(noted.id).budgeted == 777)
    check(try await category(edited.id).budgeted == 12_345)
    print("PASS: category targets preview, validation, save, apply, goals, and notes")
  }
}
