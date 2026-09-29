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

    // The register lists its upcoming date, at the range's midpoint.
    func previews() async throws -> [ScheduledTransaction] {
      try await engine.call("schedulePreviews", as: [ScheduledTransaction].self).filter { $0.scheduleId == rent.id }
    }
    let upcoming = try await previews()
    check(upcoming.count == 1 && upcoming[0].date == today && upcoming[0].amount == -120_000, "\(upcoming)")
    check(upcoming[0].status == .due && upcoming[0].recurring && upcoming[0].title == "Native Landlord")

    // Posting today adds a linked transaction, which marks the schedule paid.
    try await call("postSchedule", ["id": .string(rent.id), "today": .bool(true)])
    check(try await !previews().contains { $0.date == today }, "A paid date leaves the upcoming list")
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

    // Specific days of a monthly schedule: the last Friday and the 15th.
    var specific = ScheduleDate.Recurrence(start: today, frequency: .monthly)
    specific.specificDays = [.init(type: "FR", value: -1), .init(type: "day", value: 15)]
    try await call("saveSchedule", [
      "name": .string("Native Specific"), "accountId": .string(account.id), "amount": .number(-1_000),
      "amountOp": .string("is"), "date": ScheduleDate.recurring(specific).json,
    ])
    let specificSchedule = try await named("Native Specific")
    guard case .recurring(let savedSpecific) = specificSchedule.date else { throw EngineFailure("Expected repeating") }
    check(Set(savedSpecific.specificDays) == [.init(type: "FR", value: -1), .init(type: "day", value: 15)])
    let specificDates = try await engine.call("upcomingDates", arguments: ["date": specificSchedule.date.json,
                                                                          "count": .number(6)], as: [String].self)
    let calendar = Calendar(identifier: .gregorian)
    for day in specificDates {
      let date = BudgetDate.date(day)!
      let isFifteenth = calendar.component(.day, from: date) == 15
      let isLastFriday = calendar.component(.weekday, from: date) == 6
        && calendar.component(.month, from: calendar.date(byAdding: .day, value: 7, to: date)!) != calendar.component(.month, from: date)
      check(isFifteenth || isLastFriday, "\(day) is neither the 15th nor a last Friday")
    }
    var badPattern = specific
    badPattern.specificDays = [.init(type: "XX", value: 40)]
    try await expectFailure("saveSchedule", [
      "name": .string("Native Bad"), "amount": .number(1), "amountOp": .string("is"),
      "date": ScheduleDate.recurring(badPattern).json,
    ], "specific days")
    var weekly = specific
    weekly.frequency = .weekly
    try await call("saveSchedule", ["id": .string(specificSchedule.id), "name": .string("Native Specific"),
                                    "accountId": .string(account.id), "amount": .number(-1_000),
                                    "amountOp": .string("is"), "date": ScheduleDate.recurring(weekly).json])
    guard case .recurring(let savedWeekly) = try await named("Native Specific").date else { throw EngineFailure("Weekly") }
    check(savedWeekly.specificDays.isEmpty, "Only monthly schedules keep specific days")

    // Linking: a transaction the schedule matches can be linked and unlinked.
    _ = try await engine.call("saveTransaction", arguments: [
      "accountId": .string(account.id), "date": .string(today), "amount": .number(-1_000),
      "notes": .string("native link candidate"), "cleared": .bool(false),
    ])
    var linkable = try await engine.call("scheduleTransactions", arguments: ["id": .string(specificSchedule.id)],
                                         as: ScheduleTransactions.self)
    guard let candidate = linkable.matching.first(where: { $0.notes == "native link candidate" })
    else { throw EngineFailure("The matching transaction should be offered: \(linkable.matching.map(\.notes))") }
    check(!linkable.linked.contains { $0.id == candidate.id })
    try await call("linkScheduleTransactions", ["id": .string(specificSchedule.id),
                                                "transactionIds": .array([.string(candidate.id)])])
    linkable = try await engine.call("scheduleTransactions", arguments: ["id": .string(specificSchedule.id)],
                                     as: ScheduleTransactions.self)
    check(linkable.linked.contains { $0.id == candidate.id } && !linkable.matching.contains { $0.id == candidate.id })
    try await call("linkScheduleTransactions", ["id": .string(specificSchedule.id), "link": .bool(false),
                                                "transactionIds": .array([.string(candidate.id)])])
    check(try await !engine.call("scheduleTransactions", arguments: ["id": .string(specificSchedule.id)],
                                 as: ScheduleTransactions.self).linked.contains { $0.id == candidate.id })
    try await call("deleteSchedule", ["id": .string(specificSchedule.id)])

    // How far ahead registers list upcoming transactions.
    try await call("savePreference", ["id": .string("upcomingScheduledTransactionLength"), "value": .string("oneMonth")])
    check(try await engine.call("overview", as: BudgetOverview.self).format?.upcomingLength == "oneMonth")
    try await call("savePreference", ["id": .string("upcomingScheduledTransactionLength"), "value": .string("7")])

    try await call("deleteSchedule", ["id": .string(once.id)])
    try await call("deleteSchedule", ["id": .string(rent.id)])
    check(try await !list().contains { $0.id == once.id || $0.id == rent.id })
    print("PASS: schedules create, validate, edit, preview, post, skip, complete, restart, and delete")
  }
}
