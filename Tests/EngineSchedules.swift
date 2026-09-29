import Foundation

extension EngineSmoke {
  /// Creates, edits, posts, skips, completes, restarts, and deletes schedules as Actual's schedule pages do.
  static func schedules(data: URL, resources: URL) async throws {
    let engine = try EngineClient(dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    _ = try await activeBudget(engine)
    func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) {
      precondition(condition, message(), line: line)
    }
    @discardableResult
    func call(_ method: String, _ arguments: [String: JSONValue] = [:]) async throws -> Data {
      try await engine.call(method, arguments: arguments)
    }
    func expectFailure(_ method: String, _ arguments: [String: JSONValue], _ message: String, line: UInt = #line) async throws {
      var failed = false
      do { try await call(method, arguments) } catch {
        failed = true
        check(error.localizedDescription.contains(message), "Unexpected error: \(error.localizedDescription)", line: line)
      }
      check(failed, "\(method) should have failed", line: line)
    }
    func list() async throws -> [Schedule] { try await engine.call("schedules", as: [Schedule].self) }
    func named(_ name: String) async throws -> Schedule {
      guard let found = try await list().first(where: { $0.name == name }) else { throw EngineFailure("\(name) missing") }
      return found
    }

    let today = BudgetDate.day(Date())
    let overview = try await engine.call("overview", as: BudgetOverview.self)
    guard let account = overview.openAccounts.first(where: { !$0.offbudget }) else { throw EngineFailure("No account") }
    var monthly = ScheduleDate.Recurrence(start: today, frequency: .monthly)
    monthly.interval = 1

    // Required fields and unique names, as Actual's editor checks them.
    try await expectFailure("saveSchedule", ["name": .string("Rent"), "amount": .number(-1), "amountOp": .string("is")],
                            "Date is required")
    try await call("saveSchedule", [
      "name": .string("Native Rent"), "payeeName": .string("Native Landlord"), "accountId": .string(account.id),
      "amount": .number(-120_000), "amountOp": .string("is"), "date": ScheduleDate.recurring(monthly).json,
      "postsTransaction": .bool(false),
    ])
    try await expectFailure("saveSchedule", [
      "name": .string("Native Rent"), "amount": .number(-1), "amountOp": .string("is"), "date": .string(today),
    ], "already a schedule with this name")
    var rent = try await named("Native Rent")
    check(rent.amount == .exact(-120_000) && rent.amountOp == .`is` && rent.accountId == account.id)
    check(rent.payeeId != nil && rent.nextDate == today && rent.status == .due, "\(rent)")
    guard case .recurring(let saved) = rent.date else { throw EngineFailure("Expected a repeating date") }
    check(saved.frequency == .monthly && saved.start == today)

    // Upcoming dates for a repeating date.
    let dates = try await engine.call("upcomingDates", arguments: ["date": rent.date.json, "count": .number(3)],
                                      as: [String].self)
    check(dates.count == 3 && dates[0] == today, "\(dates)")

    // Edit: a range amount and a new name keep the same schedule.
    try await call("saveSchedule", [
      "id": .string(rent.id), "name": .string("Native Rent 2"), "payeeId": rent.payeeId.map { .string($0) } ?? .null,
      "accountId": .string(account.id), "amountOp": .string("isbetween"),
      "amount": .object(["num1": .number(-130_000), "num2": .number(-110_000)]),
      "date": rent.date.json, "postsTransaction": .bool(true),
    ])
    rent = try await named("Native Rent 2")
    check(rent.amount == .range(-130_000, -110_000) && rent.postsTransaction)

    // Posting today adds a linked transaction, which marks the schedule paid.
    try await call("postSchedule", ["id": .string(rent.id), "today": .bool(true)])
    let register = try await engine.call("register", as: [Transaction].self)
    check(register.contains { $0.accountId == account.id && $0.date == today && $0.amount == -120_000 },
          "The posted transaction should use the range's midpoint")
    check(try await named("Native Rent 2").status == .paid)

    // Skipping moves the next date a month on; completing and restarting.
    try await call("skipSchedule", ["id": .string(rent.id)])
    check(try await named("Native Rent 2").nextDate! > today)
    try await call("completeSchedule", ["id": .string(rent.id), "completed": .bool(true)])
    check(try await named("Native Rent 2").status == .completed)
    try await call("completeSchedule", ["id": .string(rent.id), "completed": .bool(false)])
    check(try await named("Native Rent 2").completed == false)

    // A one-time schedule without an account cannot post.
    try await call("saveSchedule", [
      "name": .string("Native Once"), "amount": .number(5_000), "amountOp": .string("isapprox"),
      "date": .string(today),
    ])
    let once = try await named("Native Once")
    check(once.date == .once(today) && once.accountId == nil && once.amount == .exact(5_000))
    try await expectFailure("postSchedule", ["id": .string(once.id)], "Choose an account")

    try await call("deleteSchedule", ["id": .string(once.id)])
    try await call("deleteSchedule", ["id": .string(rent.id)])
    check(try await !list().contains { $0.id == once.id || $0.id == rent.id })
    print("PASS: schedules create, validate, edit, preview, post, skip, complete, restart, and delete")
  }
}
