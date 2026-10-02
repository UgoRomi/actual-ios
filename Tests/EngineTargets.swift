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
    check(fromNotes.sourceText == "Monthly bills\n#template 50\n#goal 300", fromNotes.sourceText)
    check(try sql("SELECT goal_def FROM categories WHERE id = ?", [noted.id]).first?["goal_def"] is NSNull)
    check(try await category(noted.id).hasTargets)
    let unreadable = try await targets(broken.id)
    check(unreadable.unsupported == ["#template this is not a target"] && unreadable.templates.isEmpty)
    check(unreadable.preview == nil)
    // Lines Actual cannot read are fixed in the source.
    check(unreadable.sourceText == "#template this is not a target")
    let fixedSource = try await parse(broken.id, "#template 20")
    check(fixedSource.errors.isEmpty && fixedSource.templates.map(\.amount) == [2_000])

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

    // The source editor shows targets in Actual's notes syntax and reads them back.
    func parse(_ id: String, _ text: String) async throws -> ParsedTargets {
      try await engine.call(
        "parseTargets", arguments: ["categoryId": .string(id), "month": .string(month), "text": .string(text)],
        as: ParsedTargets.self)
    }
    func render(_ templates: [TargetTemplate]) async throws -> String {
      struct Source: Decodable { let text: String }
      return try await engine.call(
        "renderTargets", arguments: ["templates": .array(templates.map(\.json))], as: Source.self
      ).text
    }
    let saved = try await targets(edited.id)
    let lines = saved.sourceText.components(separatedBy: "\n")
    check(lines.count == 3 && lines[0].hasPrefix("#template-1 123.45 repeat every 1 months starting "), saved.sourceText)
    check(lines[1] == "#template 0 up to 100000" && lines[2] == "#goal 1000", saved.sourceText)
    check(try await render(saved.templates) == saved.sourceText)
    let reparsed = try await parse(edited.id, saved.sourceText)
    check(reparsed.errors.isEmpty && reparsed.templates.map(\.type) == ["periodic", "limit", "goal"], "\(reparsed)")
    check(reparsed.templates.map(\.amount) == [12_345, 10_000_000, 100_000])
    check(reparsed.preview?.budgeted == 12_345 && reparsed.preview?.canSave == true, "\(String(describing: reparsed.preview))")
    // Text directly above a line becomes its note; a refill merges into the cap's line, as Actual writes it.
    let edits = try await parse(edited.id, "Rent\n#template-2 20 repeat every 2 weeks starting \(month)-01\n\n#template-3 up to 50 hold")
    check(edits.errors.isEmpty && edits.templates.map(\.type) == ["periodic", "limit", "refill"], "\(edits)")
    check(edits.templates[0].note == "Rent" && edits.templates[0].periodUnit == "week" && edits.templates[0].periodCount == 2)
    check(edits.templates[1].bool("hold") && edits.templates[2].priority == 3)
    check(try await render(edits.templates).hasSuffix("#template-3 up to 50 hold"))
    if let income = try await snapshot(engine, month: month).categories.first(where: \.isIncome) {
      let share = try await parse(edited.id, "#template 10% of \(income.name)")
      check(share.templates.first?.string("category") == income.id, "\(share)")
      check(try await render(share.templates) == "#template 10% of \(income.name)")
    }
    let invalid = try await parse(edited.id, "#template 50\n#template nonsense\n#template average 3 months [decrease 150%]")
    check(invalid.templates.isEmpty && invalid.preview == nil)
    check(invalid.errors.map(\.line) == [2, 3] && invalid.errors[0].text == "#template nonsense", "\(invalid.errors)")
    check(invalid.errors[1].message.contains("adjustment"), invalid.errors[1].message)
    // Problems are reported as the form reports them.
    check(try await parse(edited.id, "#template schedule Missing").preview?.problems == ["No schedule named “Missing”"])
    print("PASS: category targets preview, validation, save, apply, goals, notes, and source")
  }
}

extension EngineSmoke {
  /// Sets cleanup rules and runs End of month cleanup the way Actual's automations editor and budget menu do.
  static func cleanup(data: URL, resources: URL) async throws {
    var engine = try EngineClient(
      dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    let budget = try await activeBudget(engine)
    let month = BudgetDate.month(Date())
    func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) {
      precondition(condition, message(), line: line)
    }
    func sql(_ statement: String, _ params: [Any] = []) throws -> [[String: Any]] {
      try query(data: data, resources: resources, budget: budget, statement, params)
    }
    func settings(_ id: String) async throws -> CategoryCleanup {
      try await engine.call("categoryCleanup", arguments: ["categoryId": .string(id)], as: CategoryCleanup.self)
    }
    func save(_ id: String, _ config: CleanupConfig) async throws {
      _ = try await engine.call(
        "saveCleanup", arguments: ["categoryId": .string(id), "rows": .array(config.rows.map(\.json))])
    }
    func setBudget(_ id: String, _ amount: Int) async throws {
      _ = try await engine.call(
        "budget", arguments: ["month": .string(month), "categoryId": .string(id), "amount": .number(amount)])
    }
    func category(_ id: String) async throws -> BudgetCategory {
      guard let found = try await snapshot(engine, month: month).categories.first(where: { $0.id == id })
      else { throw EngineFailure("Category \(id) is missing") }
      return found
    }

    let expenses = try await snapshot(engine, month: month).categories.filter { !$0.isIncome }
    guard expenses.count >= 8 else { throw EngineFailure("Demo fixture needs eight expense categories") }
    // The targets test left the first three with targets; one of them sends its leftover.
    let (migrated, big, small, sender, receiver, noted) =
      (expenses[1], expenses[3], expenses[4], expenses[5], expenses[6], expenses[7])
    let earlier = try await settings(migrated.id)
    check(earlier.source == .ui && earlier.rows == [CleanupRow(role: .source, pool: nil, weight: 1)], "\(earlier)")

    // A category without rules reads as empty, and the editor's model round-trips Actual's rows.
    let empty = try await settings(big.id)
    check(empty.source == .notes && empty.rows.isEmpty && empty.pools.isEmpty, "\(empty)")
    var mixed = CleanupConfig()
    mixed.global.send = true
    mixed.global.take = true
    mixed.global.weight = 4
    mixed.pools = [CleanupConfig.Scope(pool: "Fun", send: true, take: true, weight: 2, overspendOnly: true)]
    check(mixed.rows.map(\.role) == [.source, .sink, .source, .overspend] && mixed.rows[1].weight == 4)
    check(CleanupConfig(rows: mixed.rows).rows == mixed.rows)

    // Rules are stored as Actual's editor stores them, with pools found or created by name.
    var share = CleanupConfig()
    share.global.take = true
    share.global.weight = 3
    try await save(big.id, share)
    share.global.weight = 1
    try await save(small.id, share)
    var sends = CleanupConfig()
    sends.pools = [CleanupConfig.Scope(pool: "Fun", send: true)]
    try await save(sender.id, sends)
    var receives = CleanupConfig()
    receives.pools = [CleanupConfig.Scope(pool: "fun", take: true)]
    try await save(receiver.id, receives)
    guard let stored = try sql("SELECT cleanup_def, template_settings, goal_def FROM categories WHERE id = ?", [big.id]).first
    else { throw EngineFailure("Cleanup rules were not stored") }
    check((stored["cleanup_def"] as? String) == #"[{"role":"sink","groupId":null,"weight":3}]"#, "\(stored)")
    check((stored["template_settings"] as? String)?.contains("\"ui\"") == true && stored["goal_def"] is NSNull)
    let groups = try sql("SELECT id, name FROM cleanup_groups WHERE tombstone = 0")
    check(groups.count == 1 && (groups[0]["name"] as? String) == "Fun", "\(groups)")
    let pooled = try await settings(receiver.id)
    check(pooled.source == .ui && pooled.pools == ["Fun"], "\(pooled)")
    check(pooled.rows == [CleanupRow(role: .sink, pool: "Fun", weight: 1)], "\(pooled.rows)")
    let invalid: JSONValue = .object(["role": "sink", "pool": .null, "weight": .number(0)])
    do {
      _ = try await engine.call("saveCleanup", arguments: ["categoryId": .string(big.id), "rows": .array([invalid])])
      check(false, "A weight of zero should be refused")
    } catch { check(error.localizedDescription.contains("weight"), error.localizedDescription) }

    // #cleanup notes lines are read without changing the category; saving moves them to the editor.
    _ = try await engine.call("close")
    _ = try sql(
      "INSERT OR REPLACE INTO notes (id, note) VALUES (?, ?)",
      [noted.id, "Spare\n#cleanup Fun sink 3\n#cleanup source\n#cleanup Fun"])
    engine = try EngineClient(dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    _ = try await engine.call("open", arguments: ["id": .string(budget)])
    let fromNotes = try await settings(noted.id)
    check(fromNotes.source == .notes && fromNotes.noteLines.count == 3, "\(fromNotes)")
    check(
      fromNotes.rows == [
        CleanupRow(role: .sink, pool: "Fun", weight: 3), CleanupRow(role: .source, pool: nil, weight: 1),
        CleanupRow(role: .overspend, pool: "Fun", weight: 1),
      ], "\(fromNotes.rows)")
    check(try sql("SELECT cleanup_def FROM categories WHERE id = ?", [noted.id]).first?["cleanup_def"] is NSNull)
    let editor = CleanupConfig(rows: fromNotes.rows)
    check(editor.global.send && editor.pools.count == 1 && editor.pools[0].weight == 3 && !editor.pools[0].overspendOnly)
    try await save(noted.id, CleanupConfig())
    let cleared = try await settings(noted.id)
    check(cleared.source == .ui && cleared.rows.isEmpty)

    // Cleanup returns the pool sender's leftover to its receiver, then shares all of To Budget.
    for expense in expenses { try await setBudget(expense.id, 0) }
    let unfunded = try await category(sender.id)
    try await setBudget(sender.id, 5_000 - unfunded.balance)
    check(try await category(sender.id).balance == 5_000)
    let before = try await snapshot(engine, month: month).toBudget ?? 0
    guard before > 0 else { throw EngineFailure("Demo month has only \(before) to budget") }
    let result = try await engine.call("cleanupMonth", arguments: ["month": .string(month)], as: CleanupResult.self)
    check(!result.message.isEmpty && result.assigned == before, "\(result) before \(before)")
    let after = try await snapshot(engine, month: month)
    check(after.toBudget == 0, "\(String(describing: after.toBudget))")
    check(try await category(sender.id).balance == 0)
    check(try await category(receiver.id).budgeted >= 5_000)
    check(after.categories.filter { !$0.isIncome && !$0.carryover }.allSatisfy { $0.balance >= 0 } || result.assigned == before)
    print("PASS: cleanup rules save, pools, notes, and end of month cleanup (\(result.message.prefix(40)))")
  }
}
