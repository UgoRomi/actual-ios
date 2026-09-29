import Foundation

extension EngineSmoke {
  /// Creates, renames, hides, reorders, annotates, and deletes categories and groups,
  /// and creates, renames, closes, reopens, and deletes accounts, as Actual's mobile menus do.
  static func management(data: URL, resources: URL) async throws {
    let engine = try EngineClient(dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    _ = try await activeBudget(engine)
    let month = BudgetDate.month(Date())
    func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) {
      precondition(condition, message(), line: line)
    }
    @discardableResult
    func call(_ method: String, _ arguments: [String: JSONValue]) async throws -> Data {
      try await engine.call(method, arguments: arguments)
    }
    func created(_ method: String, _ arguments: [String: JSONValue]) async throws -> String {
      struct Created: Decodable { let id: String }
      return try JSONDecoder().decode(Created.self, from: try await call(method, arguments)).id
    }
    func expectFailure(_ method: String, _ arguments: [String: JSONValue], _ message: String, line: UInt = #line) async throws {
      var failed = false
      do { try await call(method, arguments) } catch {
        failed = true
        check(error.localizedDescription.contains(message), "Unexpected error: \(error.localizedDescription)", line: line)
      }
      check(failed, "\(method) should have failed", line: line)
    }
    func budget() async throws -> BudgetMonth {
      try await engine.call("budgetMonth", arguments: ["month": .string(month)], as: BudgetMonth.self)
    }
    func group(_ id: String) async throws -> CategoryGroup {
      guard let found = try await budget().groups.first(where: { $0.id == id }) else { throw EngineFailure("Group \(id) missing") }
      return found
    }
    func overview() async throws -> BudgetOverview { try await engine.call("overview", as: BudgetOverview.self) }

    // Groups and categories.
    try await expectFailure("createCategoryGroup", ["name": .string("  ")], "Enter a name")
    let groupID = try await created("createCategoryGroup", ["name": .string("Native Group")])
    let first = try await created("createCategory", ["groupId": .string(groupID), "name": .string("Alpha")])
    let second = try await created("createCategory", ["groupId": .string(groupID), "name": .string("Beta")])
    var native = try await group(groupID)
    check(native.name == "Native Group" && !native.isIncome && Set(native.categories.map(\.id)) == [first, second])
    try await expectFailure("updateCategory", ["id": .string(second), "name": .string("alpha")], "already exists")
    try await call("updateCategory", ["id": .string(first), "name": .string("Alpha Renamed")])
    try await call("updateCategoryGroup", ["id": .string(groupID), "name": .string("Native Renamed")])
    native = try await group(groupID)
    check(native.name == "Native Renamed" && native.categories.contains { $0.name == "Alpha Renamed" })

    // Reorder: move the last category first, then back to the end.
    let order = native.categories.map(\.id)
    try await call("moveCategory", ["id": .string(order[1]), "targetId": .string(order[0])])
    check(try await group(groupID).categories.map(\.id) == [order[1], order[0]])
    try await call("moveCategory", ["id": .string(order[1])])
    check(try await group(groupID).categories.map(\.id) == order)

    // Hidden categories and groups stay in the month, flagged.
    try await call("updateCategory", ["id": .string(second), "hidden": .bool(true)])
    try await call("updateCategoryGroup", ["id": .string(groupID), "hidden": .bool(true)])
    let hidden = try await budget()
    check(hidden.groups.first { $0.id == groupID }?.hidden == true)
    check(hidden.categories.first { $0.id == second }?.hidden == true)
    check(!hidden.visibleGroups.contains { $0.id == groupID })
    try await call("updateCategoryGroup", ["id": .string(groupID), "hidden": .bool(false)])
    check(try await budget().visibleGroups.first { $0.id == groupID }?.categories.map(\.id) == [first])

    // Notes for a category, a group, and the month.
    try await call("saveNotes", ["id": .string(first), "note": .string("Category note")])
    try await call("saveNotes", ["id": .string(groupID), "note": .string("Group note")])
    try await call("saveNotes", ["id": .string("budget-\(month)"), "note": .string("Month note")])
    let noted = try await budget()
    check(noted.categories.first { $0.id == first }?.notes == "Category note")
    check(noted.groups.first { $0.id == groupID }?.notes == "Group note")
    check(noted.notes == "Month note")

    // A category with a budget must hand it to another category when deleted.
    _ = try await engine.call("budget", arguments: [
      "month": .string(month), "categoryId": .string(first), "amount": .number(4_200),
    ])
    struct Needs: Decodable { let required: Bool }
    check(try await engine.call("categoryNeedsTransfer", arguments: ["id": .string(first)], as: Needs.self).required)
    check(try await !engine.call("categoryNeedsTransfer", arguments: ["id": .string(second)], as: Needs.self).required)
    try await expectFailure("deleteCategory", ["id": .string(first)], "Choose a category to receive")
    try await expectFailure("deleteCategory", ["id": .string(first), "transferId": .string(first)], "not being deleted")
    try await call("deleteCategory", ["id": .string(second)])
    let receiver = try await created("createCategory", ["groupId": .string(groupID), "name": .string("Receiver")])
    try await call("deleteCategory", ["id": .string(first), "transferId": .string(receiver)])
    let afterDelete = try await budget()
    check(!afterDelete.categories.contains { $0.id == first || $0.id == second })
    check(afterDelete.categories.first { $0.id == receiver }?.budgeted == 4_200)

    // A group whose categories have budgets needs a receiving category too.
    guard let outside = afterDelete.expenseCategories.first(where: { !native.categories.map(\.id).contains($0.id) && $0.id != receiver })
    else { throw EngineFailure("Demo fixture needs another expense category") }
    try await expectFailure("deleteCategoryGroup", ["id": .string(groupID)], "Choose a category to receive")
    let outsideBefore = outside.budgeted
    try await call("deleteCategoryGroup", ["id": .string(groupID), "transferId": .string(outside.id)])
    let afterGroup = try await budget()
    check(!afterGroup.groups.contains { $0.id == groupID })
    check(afterGroup.categories.first { $0.id == outside.id }?.budgeted == outsideBefore + 4_200)

    // Accounts: create with a starting balance, rename, and names stay unique.
    let savings = try await created("createAccount", [
      "name": .string("Native Savings"), "balance": .number(12_345), "offBudget": .bool(false),
    ])
    let loan = try await created("createAccount", [
      "name": .string("Native Loan"), "balance": .number(-50_000), "offBudget": .bool(true),
    ])
    let empty = try await created("createAccount", ["name": .string("Native Empty")])
    var accounts = try await overview().accounts
    check(accounts.first { $0.id == savings }?.balance == 12_345)
    check(accounts.first { $0.id == loan }?.offbudget == true && accounts.first { $0.id == loan }?.balance == -50_000)
    try await expectFailure("createAccount", ["name": .string("Native Savings")], "already exists")
    try await expectFailure("updateAccount", ["id": .string(savings), "name": .string("")], "cannot be blank")
    try await call("updateAccount", ["id": .string(savings), "name": .string("Native Reserve")])
    try await call("saveNotes", ["id": .string("account-\(savings)"), "note": .string("Account note")])
    accounts = try await overview().accounts
    check(accounts.first { $0.id == savings }?.name == "Native Reserve")
    check(accounts.first { $0.id == savings }?.notes == "Account note")

    // Closing: a balance must move; on budget to off budget needs a category.
    try await expectFailure("closeAccount", ["id": .string(savings)], "Choose an account to receive")
    try await expectFailure("closeAccount", ["id": .string(savings), "transferAccountId": .string(loan)], "Choose a category for the transfer")
    try await call("closeAccount", [
      "id": .string(savings), "transferAccountId": .string(loan), "categoryId": .string(outside.id),
    ])
    accounts = try await overview().accounts
    check(accounts.first { $0.id == savings }?.closed == true && accounts.first { $0.id == savings }?.balance == 0)
    check(accounts.first { $0.id == loan }?.balance == -50_000 + 12_345)
    try await expectFailure("closeAccount", ["id": .string(savings)], "already closed")
    try await call("reopenAccount", ["id": .string(savings)])
    check(try await overview().accounts.first { $0.id == savings }?.closed == false)

    // Without transactions, closing deletes; force closing deletes one with transactions.
    try await call("closeAccount", ["id": .string(empty)])
    check(try await !overview().accounts.contains { $0.id == empty })
    try await call("closeAccount", ["id": .string(loan), "forced": .bool(true)])
    let register = try await engine.call("register", as: [Transaction].self)
    check(!register.contains { $0.accountId == loan })
    check(try await !overview().accounts.contains { $0.id == loan })

    // Payees: rename, merge (moving transactions), and delete unused ones.
    struct Listed: Decodable { let id: String; let name: String; let ruleCount: Int; let unused: Bool }
    func payees() async throws -> [Listed] { try await engine.call("payees", as: [Listed].self) }
    let keep = try await created("createAccount", ["name": .string("Native Payee Account")])
    for (index, payee) in ["Native Cafe", "native café", "Native Unused"].enumerated() {
      _ = try await engine.call("saveTransaction", arguments: [
        "accountId": .string(keep), "date": .string("2026-09-20"), "amount": .number(-100 - index),
        "payeeName": .string(payee), "notes": .string(""), "cleared": .bool(false),
      ])
    }
    var listed = try await payees()
    guard let cafe = listed.first(where: { $0.name == "Native Cafe" }),
          let accented = listed.first(where: { $0.name == "native café" }),
          let spare = listed.first(where: { $0.name == "Native Unused" })
    else { throw EngineFailure("Payees missing: \(listed.map(\.name))") }
    check(!listed.contains { $0.name.isEmpty }, "Transfer payees are not listed")
    try await expectFailure("renamePayee", ["id": .string(cafe.id), "name": .string(" ")], "Enter a name")
    try await call("renamePayee", ["id": .string(cafe.id), "name": .string("Native Coffee")])
    try await call("mergePayees", ["targetId": .string(cafe.id), "mergeIds": .array([.string(accented.id)])])
    listed = try await payees()
    check(listed.contains { $0.id == cafe.id && $0.name == "Native Coffee" } && !listed.contains { $0.id == accented.id })
    let moved = try await engine.call("register", as: [Transaction].self).filter { $0.accountId == keep }
    check(moved.filter { $0.payeeId == cafe.id }.count == 2, "Merged transactions move to the kept payee")
    // A payee whose transactions are deleted becomes unused, and can be deleted.
    for transaction in moved where transaction.payeeId == spare.id {
      try await call("deleteTransaction", ["id": .string(transaction.id)])
    }
    check(try await payees().first { $0.id == spare.id }?.unused == true)
    try await call("deletePayees", ["ids": .array([.string(spare.id)])])
    check(try await !payees().contains { $0.id == spare.id })
    let transferPayee = try await engine.call("overview", as: BudgetOverview.self).accounts.first!.id
    try await expectFailure("mergePayees", ["targetId": .string(cafe.id), "mergeIds": .array([.string(transferPayee)])],
                            "no longer exists")
    // Tags: discovered from notes, colored, renamed in every note, hidden, and deleted.
    func tags() async throws -> [Tag] { try await engine.call("tags", as: [Tag].self) }
    _ = try await engine.call("saveTransaction", arguments: [
      "accountId": .string(keep), "date": .string("2026-09-21"), "amount": .number(-900),
      "payeeName": .string("Native Tag Shop"), "notes": .string("trip #nativetrip ##escaped"), "cleared": .bool(false),
    ])
    try await call("discoverTags", [:])
    guard let trip = try await tags().first(where: { $0.tag == "nativetrip" }) else { throw EngineFailure("Tag not discovered") }
    check(try await !tags().contains { $0.tag == "escaped" || $0.tag == "#escaped" }, "## escapes a tag")
    try await expectFailure("createTag", ["tag": .string("two words")], "without spaces")
    try await call("createTag", ["tag": .string("#nativeextra"), "color": .string("#112233")])
    check(try await tags().first { $0.tag == "nativeextra" }?.color == "#112233")
    try await expectFailure("updateTag", ["id": .string(trip.id), "color": .string("red")], "valid color")
    try await call("updateTag", ["id": .string(trip.id), "tag": .string("nativejourney"), "color": .string("#AA00FF"),
                                 "description": .string("Holidays"), "hidden": .bool(true)])
    let renamed = try await tags().first { $0.id == trip.id }
    check(renamed?.tag == "nativejourney" && renamed?.color == "#AA00FF" && renamed?.description == "Holidays" && renamed?.hidden == true)
    let tagged = try await engine.call("register", as: [Transaction].self).first { $0.accountId == keep && $0.amount == -900 }
    check(tagged?.notes == "trip #nativejourney ##escaped", "Renaming changes the tag in notes: \(String(describing: tagged?.notes))")
    check(try await engine.call("overview", as: BudgetOverview.self).tags.contains { $0.tag == "nativejourney" })
    try await call("deleteTag", ["id": .string(trip.id)])
    check(try await !tags().contains { $0.id == trip.id })

    // Formatting settings sync with the budget, limited to Actual's choices.
    try await call("savePreference", ["id": .string("numberFormat"), "value": .string("dot-comma")])
    try await call("savePreference", ["id": .string("hideFraction"), "value": .string("true")])
    try await call("savePreference", ["id": .string("dateFormat"), "value": .string("dd.MM.yyyy")])
    try await call("savePreference", ["id": .string("firstDayOfWeekIdx"), "value": .string("1")])
    let format = try await engine.call("overview", as: BudgetOverview.self).format
    check(format == BudgetFormat(numberFormat: "dot-comma", hideFraction: true, dateFormat: "dd.MM.yyyy", firstDayOfWeekIdx: 1),
          "\(String(describing: format))")
    try await expectFailure("savePreference", ["id": .string("numberFormat"), "value": .string("weird")], "offered settings")
    try await expectFailure("savePreference", ["id": .string("budgetType"), "value": .string("tracking")], "offered settings")
    try await call("savePreference", ["id": .string("hideFraction"), "value": .string("false")])
    print("PASS: management of categories, groups, notes, accounts, payees, and formatting")
  }
}
