import Foundation

extension EngineSmoke {
  /// Lists, validates, creates, matches, applies, edits, and deletes rules as Actual's rules pages do.
  static func rules(data: URL, resources: URL) async throws {
    let engine = try EngineClient(dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    _ = try await activeBudget(engine)
    func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) {
      precondition(condition, message(), line: line)
    }
    func list() async throws -> [Rule] { try await engine.call("rules", as: [Rule].self) }
    func expectFailure(_ method: String, _ arguments: [String: JSONValue], _ message: String, line: UInt = #line) async throws {
      var failed = false
      do { _ = try await engine.call(method, arguments: arguments) } catch {
        failed = true
        check(error.localizedDescription.contains(message), "Unexpected error: \(error.localizedDescription)", line: line)
      }
      check(failed, "\(method) should have failed", line: line)
    }

    // The demo's rules decode, and each has a description; schedule rules are marked.
    let existing = try await list()
    let describer = RuleDescriber(payees: [:], accounts: [:], categories: [:], currency: "")
    check(existing.allSatisfy { !describer.describe($0).isEmpty })
    guard let scheduleRule = existing.first(where: \.isSchedule) else { throw EngineFailure("Demo has no schedule rules") }
    check(!scheduleRule.isEditable)

    let overview = try await engine.call("overview", as: BudgetOverview.self)
    guard let account = overview.openAccounts.first(where: { !$0.offbudget }) else { throw EngineFailure("No account") }
    let categories = try await snapshot(engine, month: BudgetDate.month(Date())).categories.filter { !$0.isIncome }
    let (food, fun) = (categories[0].id, categories[1].id)

    // A transaction to match, from a new payee.
    _ = try await engine.call("saveTransaction", arguments: [
      "accountId": .string(account.id), "date": .string(BudgetDate.day(Date())), "amount": .number(-4_321),
      "payeeName": .string("Native Rule Shop"), "notes": .string("receipt"), "cleared": .bool(false),
    ])
    guard let payee = try await engine.call("overview", as: BudgetOverview.self).payees.first(where: { $0.name == "Native Rule Shop" })
    else { throw EngineFailure("Payee missing") }

    // Actual's validation reports each bad condition.
    var bad = Rule.new()
    bad.conditions = [RuleItem(raw: ["field": .string("amount"), "op": .string("is"), "type": .string("number"),
                                     "value": .string("lots")])]
    try await expectFailure("saveRule", bad.json, "Condition 1")
    var empty = Rule.new()
    empty.actions = []
    try await expectFailure("saveRule", empty.json, "Add at least one action")

    // If payee is the shop and the outflow is over 40, set the category and add to the notes.
    var rule = Rule.new()
    var payeeCondition = RuleItem.condition(field: "payee")
    payeeCondition.raw["value"] = .string(payee.id)
    var amountCondition = RuleItem.condition(field: "amount", op: "gt")
    amountCondition.raw["options"] = .object(["outflow": .bool(true)])
    amountCondition.raw["value"] = .number(4_000)
    rule.conditions = [payeeCondition, amountCondition]
    var setCategory = RuleItem.action(field: "category")
    setCategory.raw["value"] = .string(food)
    let appendNotes = RuleItem.action(field: "notes").withActionOp("append-notes")
    var append = appendNotes
    append.raw["value"] = .string(" (ruled)")
    rule.actions = [setCategory, append]
    check(rule.isEditable && rule.conditions.allSatisfy(\.isEditableCondition))
    struct Saved: Decodable { let id: String }
    struct Count: Decodable { let count: Int }
    rule.id = try await engine.call("saveRule", arguments: rule.json, as: Saved.self).id
    guard let saved = try await list().first(where: { $0.id == rule.id }) else { throw EngineFailure("Rule missing") }
    check(saved.conditions.count == 2 && saved.actions.count == 2 && saved.isEditable)
    check(try await engine.call("ruleMatches", arguments: saved.json, as: Count.self).count == 1)

    // Applying runs its actions on the matching transaction.
    check(try await engine.call("applyRule", arguments: saved.json, as: Count.self).count == 1)
    var matched = try await engine.call("register", as: [Transaction].self).first { $0.payeeId == payee.id }
    check(matched?.categoryId == food && matched?.notes == "receipt (ruled)", "\(String(describing: matched))")

    // Editing changes what new transactions get.
    var edited = saved
    edited.actions[0].raw["value"] = .string(fun)
    _ = try await engine.call("saveRule", arguments: edited.json)
    _ = try await engine.call("saveTransaction", arguments: [
      "accountId": .string(account.id), "date": .string(BudgetDate.day(Date())), "amount": .number(-5_000),
      "payeeId": .string(payee.id), "notes": .string(""), "cleared": .bool(false),
    ])
    matched = try await engine.call("register", as: [Transaction].self).first { $0.payeeId == payee.id && $0.amount == -5_000 }
    check(matched?.categoryId == fun, "New transactions use the edited rule")

    // A category group condition matches the group's categories.
    let budget = try await snapshot(engine, month: BudgetDate.month(Date()))
    guard let foodGroup = budget.groups.first(where: { $0.categories.contains { $0.id == food } }) else {
      throw EngineFailure("Group missing")
    }
    var byGroup = Rule.new()
    byGroup.conditions = [RuleItem.condition(field: "category_group")]
    byGroup.conditions[0].raw["value"] = .string(foodGroup.id)
    check(byGroup.isEditable)
    struct Matches: Decodable { let count: Int; let transactions: [RuleMatch] }
    let groupMatches = try await engine.call("ruleMatches", arguments: byGroup.json, as: Matches.self)
    check(groupMatches.count > 0 && groupMatches.transactions.contains { $0.categoryId == food })

    // A split rule: a fixed 10.00 for food, and the rest for fun.
    var split = Rule.new()
    split.conditions = [payeeCondition]
    split.actions = []
    split.addSplit()
    split.addSplit()
    check(split.splitCount == 2 && split.actions.map(\.op) == ["set-split-amount", "set", "set-split-amount", "set"])
    check(RuleItem.actionFields(split: 1) == ["category", "payee", "notes"])
    split.actions[0] = split.actions[0].withSplitMethod("fixed-amount")
    split.actions[0].raw["value"] = .number(-1_000)
    split.actions[1].raw["value"] = .string(food)
    split.actions[3].raw["value"] = .string(fun)
    check(split.isEditable && split.actions[2].splitMethod == "remainder")
    check(describer.describe(split).contains("split into split 1: allocate a fixed amount"), describer.describe(split))
    split.id = try await engine.call("saveRule", arguments: split.json, as: Saved.self).id
    guard let savedSplit = try await list().first(where: { $0.id == split.id }) else { throw EngineFailure("Split rule missing") }
    check(savedSplit.isEditable && savedSplit.splitCount == 2)

    // Applying to one chosen match splits only that transaction.
    let splitMatches = try await engine.call("ruleMatches", arguments: savedSplit.json, as: Matches.self)
    check(splitMatches.count == 2, "\(splitMatches.count)")
    guard let larger = splitMatches.transactions.first(where: { $0.amount == -5_000 }) else { throw EngineFailure("Match missing") }
    var chosen = savedSplit.json
    chosen["ids"] = .array([.string(larger.id)])
    check(try await engine.call("applyRule", arguments: chosen, as: Count.self).count == 1)
    let register = try await engine.call("register", as: [Transaction].self)
    let splitTransaction = register.first { $0.id == larger.id }
    check(splitTransaction?.isParent == true && splitTransaction?.splits?.map(\.amount) == [-1_000, -4_000],
          "\(String(describing: splitTransaction))")
    check(splitTransaction?.splits?.map(\.categoryId) == [food, fun])
    check(register.first { $0.payeeId == payee.id && $0.amount == -4_321 }?.isParent == false)

    // As Actual's register's "Create rule": a split's parts become the draft's splits.
    let draft = try await engine.call("ruleFromTransaction", arguments: ["id": .string(larger.id)], as: Rule.self)
    check(draft.id.isEmpty && draft.isEditable && draft.splitCount == 2, "\(draft)")
    check(draft.conditions.map(\.field) == ["payee", "amount"] && draft.conditions[1].op == "isapprox")
    check(draft.actions.filter { $0.op == "set-split-amount" }.map(\.value) == [.number(-1_000), .number(-4_000)])
    guard let smaller = register.first(where: { $0.payeeId == payee.id && $0.amount == -4_321 }) else { throw EngineFailure("Missing") }
    let plain = try await engine.call("ruleFromTransaction", arguments: ["id": .string(smaller.id)], as: Rule.self)
    check(plain.splitCount == 0 && plain.actions.first?.value == .string(food), "\(plain)")

    // A payee's rules, as its page lists them.
    let payeeRules = try await engine.call("rules", arguments: ["payeeId": .string(payee.id)], as: [Rule].self)
    check(Set(payeeRules.map(\.id)) == [rule.id, split.id], "\(payeeRules.map(\.id))")

    // Completed schedules' rules are not listed, as on Actual's rules page.
    let schedules = try await engine.call("schedules", as: [Schedule].self)
    if let open = schedules.first(where: { !$0.completed }) {
      let before = try await list().count
      _ = try await engine.call("completeSchedule", arguments: ["id": .string(open.id), "completed": .bool(true)])
      check(try await list().count == before - 1)
      _ = try await engine.call("completeSchedule", arguments: ["id": .string(open.id), "completed": .bool(false)])
      check(try await list().count == before)
    }

    // Deleting several keeps schedules' rules and deletes the rest.
    try await expectFailure("deleteRules", ["ids": .array([.string(split.id), .string(scheduleRule.id)])], "belong to schedules")
    let remaining = try await list()
    check(!remaining.contains { $0.id == split.id } && remaining.contains { $0.id == scheduleRule.id })

    // A schedule's rule stays with the schedule; others can be deleted.
    try await expectFailure("deleteRule", ["id": .string(scheduleRule.id)], "belongs to a schedule")
    _ = try await engine.call("deleteRule", arguments: ["id": .string(rule.id)])
    check(try await !list().contains { $0.id == rule.id })
    print("PASS: rules list, validate, create, split, match, apply, draft, edit, and delete")
  }
}
