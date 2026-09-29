import Foundation

extension EngineSmoke {
  /// Runs Actual's budget menu actions: month actions, a category's copy and
  /// averages, rollover, and moving money between categories, To Budget, and next month.
  static func budgetActions(data: URL, resources: URL) async throws {
    let engine = try EngineClient(dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    let budget = try await activeBudget(engine)
    let month = BudgetDate.month(Date())
    let previous = BudgetDate.month(Calendar(identifier: .gregorian).date(byAdding: .month, value: -1, to: Date())!)
    let next = BudgetDate.month(Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: Date())!)
    func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) {
      precondition(condition, message(), line: line)
    }
    func act(_ action: BudgetAction, in m: String? = nil) async throws {
      _ = try await engine.call("budgetAction", arguments: [
        "month": .string(m ?? month), "action": .string(action.name), "args": .object(action.arguments),
      ])
    }
    func expectFailure(_ action: BudgetAction, _ message: String, line: UInt = #line) async throws {
      var failed = false
      do { try await act(action) } catch {
        failed = true
        check(error.localizedDescription.contains(message), "Unexpected error: \(error.localizedDescription)", line: line)
      }
      check(failed, "\(action) should have failed", line: line)
    }
    func state(_ m: String? = nil) async throws -> BudgetMonth {
      try await engine.call("budgetMonth", arguments: ["month": .string(m ?? month)], as: BudgetMonth.self)
    }
    func category(_ id: String, _ m: String? = nil) async throws -> BudgetCategory {
      guard let found = try await state(m).categories.first(where: { $0.id == id })
      else { throw EngineFailure("Category \(id) is missing") }
      return found
    }
    func setBudget(_ id: String, _ amount: Int, _ m: String? = nil) async throws {
      _ = try await engine.call("budget", arguments: [
        "month": .string(m ?? month), "categoryId": .string(id), "amount": .number(amount),
      ])
    }

    let initial = try await state()
    check(initial.budgetType == .envelope && initial.envelope != nil, "Budget actions need an envelope budget")
    let expenses = initial.expenseCategories
    guard expenses.count >= 3 else { throw EngineFailure("Demo fixture needs three expense categories") }
    let (a, b, c) = (expenses[0].id, expenses[1].id, expenses[2].id)

    // Month actions: zero, then copy last month's amounts.
    try await setBudget(a, 11_100, previous)
    try await act(.setZero)
    check(try await state().expenseCategories.allSatisfy { $0.budgeted == 0 })
    try await act(.copyLastMonth)
    check(try await category(a).budgeted == 11_100)
    try await act(.setAverage(months: 3))

    // One category: copy and averages.
    try await setBudget(b, 0)
    try await setBudget(b, 7_700, previous)
    try await act(.copyLastMonthFor(category: b))
    check(try await category(b).budgeted == 7_700)
    try await act(.setAverageFor(category: b, months: 6))
    try await expectFailure(.setAverageFor(category: b, months: 4), "3, 6, or 12")

    // Start from nothing budgeted, so To Budget holds this month's funds.
    try await act(.setZero)
    let funded = try await state()
    guard let available = funded.toBudget, available > 20_000
    else { throw EngineFailure("Demo fixture needs money to budget") }

    // To Budget → category, category → category, category → To Budget.
    // Enough to cover this month's spending, with 10,000 left over.
    let fund = 10_000 - min(try await category(a).balance, 0)
    guard available > fund + 20_000 else { throw EngineFailure("Demo fixture needs money to budget") }
    try await act(.transferAvailable(to: a, amount: fund))
    check(try await category(a).budgeted == fund)
    check(try await state().toBudget == available - fund)
    let aBalance = try await category(a).balance
    try await act(.transfer(from: a, to: .category(b), amount: 4_000))
    check(try await category(a).balance == aBalance - 4_000)
    check(try await category(b).budgeted == 4_000)
    try await act(.transfer(from: a, to: .toBudget, amount: 1_000))
    check(try await state().toBudget == available - fund + 1_000)
    try await expectFailure(.transfer(from: a, to: .category(a), amount: 100), "different category")
    try await expectFailure(.transfer(from: a, to: .category(b), amount: aBalance * 10), "does not have that much")
    try await expectFailure(.transferAvailable(to: a, amount: 0), "greater than zero")

    // Movements are recorded in the month's notes, as in Actual.
    let notes = try query(data: data, resources: resources, budget: budget,
                          "SELECT note FROM notes WHERE id = ?", ["budget-\(month)"])
    check((notes.first?["note"] as? String)?.contains("Reassigned") == true, "\(notes)")

    // Cover an overspent category from To Budget, then from another category's balance.
    try await setBudget(c, (try await category(c).budgeted) - (try await category(c).balance) - 5_000)
    check(try await category(c).balance == -5_000)
    try await act(.coverOverspending(category: c, from: .toBudget, amount: 5_000))
    check(try await category(c).balance == 0)
    try await setBudget(c, (try await category(c).budgeted) - 500)
    let aBefore = try await category(a).balance
    try await act(.coverOverspending(category: c, from: .category(a), amount: 500))
    check(try await category(c).balance == 0)
    check(try await category(a).balance == aBefore - 500)

    // Cover an overbudgeted month from a category.
    let toBudget = try await state().toBudget ?? 0
    try await setBudget(a, (try await category(a).budgeted) + toBudget + 3_000)
    check(try await state().toBudget == -3_000)
    try await act(.coverOverbudgeted(from: a, amount: 3_000))
    check(try await state().toBudget == 0)

    // Hold money for next month, then release it.
    try await setBudget(a, (try await category(a).budgeted) - 6_000)
    // As in Actual, holding adds to what is already held.
    let heldBefore = try await state().envelope?.manualHold ?? 0
    try await act(.hold(amount: 2_500))
    let held = try await state()
    check(held.envelope?.manualHold == heldBefore + 2_500, "\(String(describing: held.envelope))")
    check(held.toBudget == 3_500)
    try await act(.resetHold)
    check(try await state().envelope?.manualHold == 0)
    try await act(.disableAutoHold)

    // Rollover applies from this month onward.
    try await act(.rollover(category: c, enabled: true))
    let rolledOver = try await category(c).carryover, rolledOverNext = try await category(c, next).carryover
    check(rolledOver && rolledOverNext)
    check(try await category(c, previous).carryover == false)
    try await act(.rollover(category: c, enabled: false))
    check(try await category(c).carryover == false)

    // Income categories cannot hold budget moves.
    if let income = initial.categories.first(where: \.isIncome) {
      try await expectFailure(.transferAvailable(to: income.id, amount: 100), "expense category")
    }
    print("PASS: budget actions copy, zero, average, transfer, cover, hold, and rollover")
  }
}
