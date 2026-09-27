import Foundation

extension EngineSmoke {
  /// Checks every natively drawn report against sums read directly from Actual's transaction view.
  static func reports(data: URL, resources: URL) async throws {
    let engine = try EngineClient(dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    _ = try await engine.call("demo")
    let budget = try await activeBudget(engine)
    func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) {
      precondition(condition, message(), line: line)
    }
    func sql(_ statement: String, _ params: [Any] = []) throws -> [[String: Any]] {
      try query(data: data, resources: resources, budget: budget, statement, params)
    }
    func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
    /// Sums what Actual's `transactions` queries see: splits inline, parents excluded.
    func sum(_ condition: String, _ params: [Any] = []) throws -> Int {
      int(try sql("""
        SELECT IFNULL(SUM(t.amount), 0) AS total FROM v_transactions t
        LEFT JOIN accounts a ON a.id = t.account
        LEFT JOIN categories c ON c.id = t.category
        WHERE t.is_parent = 0 AND t.account IS NOT NULL AND \(condition)
        """, params).first?["total"])
    }
    let calendar = Calendar(identifier: .gregorian)
    let now = Date()
    func day(_ date: Date) -> Int { Int(BudgetDate.day(date).replacingOccurrences(of: "-", with: ""))! }
    func monthStart(_ offset: Int) -> Date {
      calendar.date(byAdding: .month, value: offset, to: calendar.date(from: calendar.dateComponents([.year, .month], from: now))!)!
    }
    func monthEnd(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: -1, to: monthStart(offset + 1))! }
    let today = day(now)
    let currentMonth = BudgetDate.month(now)
    /// JavaScript's Math.round.
    func jsRound(_ value: Double) -> Int { Int((value + 0.5).rounded(.down)) }

    func dashboard() async throws -> ReportsDashboard {
      try await engine.call("reportsDashboard", as: ReportsDashboard.self)
    }
    func report(_ id: String, _ options: [String: JSONValue] = [:]) async throws -> ReportData {
      try await engine.call("report", arguments: ["id": .string(id), "options": .object(options)], as: ReportData.self)
    }

    // The demo has Actual's default dashboard: widgets top to bottom, then left to right.
    var pages = try await dashboard().pages
    check(!pages.isEmpty, "Every budget has a dashboard")
    let page = pages[0]
    let types = page.widgets.map(\.type)
    check(types == ["summary-card", "summary-card", "summary-card", "summary-card", "net-worth-card", "cash-flow-card",
                    "spending-card", "spending-card", "spending-card", "calendar-card", "summary-card", "markdown-card"],
          "Unexpected order \(types)")
    check(page.widgets[0].title == "Total Income (YTD)" && page.widgets[6].title == "This Month")
    func widget(_ type: String) -> String { page.widgets.first { $0.type == type }!.id }

    // Widgets as Actual's editor stores them, with filters and time frames.
    let accounts = try await engine.call("overview", as: BudgetOverview.self).accounts
    guard let checking = accounts.first(where: { !$0.offbudget && !$0.closed }) else {
      throw EngineFailure("Demo needs an on-budget account")
    }
    let expenses = #"[{"field":"amount","op":"lt","value":0},{"field":"account","op":"onBudget","value":""},{"field":"transfer","op":"is","value":false}]"#
    func summaryMeta(_ type: String, _ extra: String = "") -> String {
      let content = "{\\\"type\\\":\\\"\(type)\\\"\(extra)}"
      return #"{"name":"S \#(type)","content":"\#(content)","timeFrame":{"start":"2024-01-01","end":"2024-12-31","mode":"yearToDate"},"conditions":\#(expenses),"conditionsOp":"and"}"#
    }
    let seeded: [(id: String, type: String, y: Int, x: Int, meta: String?)] = [
      ("w-sum", "summary-card", 20, 0, summaryMeta("sum")),
      ("w-month", "summary-card", 20, 3, summaryMeta("avgPerMonth")),
      ("w-tx", "summary-card", 20, 6, summaryMeta("avgPerTransact")),
      ("w-pct", "summary-card", 20, 9, summaryMeta("percentage", #",\"divisorConditions\":[{\"field\":\"amount\",\"op\":\"gt\",\"value\":0}],\"divisorConditionsOp\":\"and\""#)),
      ("w-cal", "calendar-card", 21, 0, #"{"name":"Cal","timeFrame":{"start":"2024-01","end":"2024-03","mode":"sliding-window"},"conditions":[{"field":"transfer","op":"is","value":false}],"conditionsOp":"and"}"#),
      ("w-text", "markdown-card", 22, 0, ###"{"content":"## Tips\n\nSome **bold** text.","text_align":"center"}"###),
      ("w-custom", "custom-report", 23, 0, #"{"id":"missing-report"}"#),
      ("w-sankey", "sankey-card", 24, 0, nil),
      ("w-nw-one", "net-worth-card", 25, 0, #"{"name":"One account","conditions":[{"field":"account","op":"is","value":"\#(checking.id)"}],"conditionsOp":"and","timeFrame":{"start":"2026-01","end":"2026-03","mode":"yearToDate"}}"#),
    ]
    for widget in seeded {
      _ = try sql(
        "INSERT INTO dashboard (id, type, width, height, x, y, meta, tombstone, dashboard_page_id) VALUES (?, ?, 3, 2, ?, ?, ?, 0, ?)",
        [widget.id, widget.type, widget.x, widget.y, widget.meta ?? NSNull(), page.id])
    }
    pages = try await dashboard().pages
    let shown = pages[0].widgets
    check(!shown.contains { $0.type == "sankey-card" }, "Experimental widgets stay hidden while their flag is off")
    check(Array(shown.suffix(8).map(\.id)) == ["w-sum", "w-month", "w-tx", "w-pct", "w-cal", "w-text", "w-custom", "w-nw-one"],
          "Seeded widgets out of order: \(shown.map(\.id))")
    let text = shown.first { $0.id == "w-text" }
    check(text?.content == "## Tips\n\nSome **bold** text." && text?.textAlign == "center" && text?.kind == .markdown)
    check(shown.first { $0.id == "w-custom" }?.title == "Custom Report", "A missing custom report keeps its default name")
    // Actual's flag turns on the experimental widget.
    _ = try sql("INSERT INTO preferences (id, value) VALUES ('flags.sankeyReport', 'true')")
    check(try await dashboard().pages[0].widgets.contains { $0.id == "w-sankey" }, "A flagged widget appears once its flag is on")
    _ = try sql("DELETE FROM preferences WHERE id = 'flags.sankeyReport'")

    // Net worth: every account, by month, over the default six months.
    let netWorthID = widget("net-worth-card")
    guard let netWorth = try await report(netWorthID).netWorth else { throw EngineFailure("Net worth missing") }
    let throughMonth = day(monthEnd(0))
    check(netWorth.netWorth == (try sum("t.date <= ?", [throughMonth])), "Net worth \(netWorth.netWorth)")
    check(netWorth.points.last?.date == currentMonth && netWorth.points.count >= 6, "\(netWorth.points.map(\.date))")
    // Each month's net worth is every balance at its end.
    func checkMonths(_ report: NetWorthReport) throws {
      for point in report.points {
        guard let start = ReportDate.date(point.date),
              let end = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start) else { continue }
        check(point.total == (try sum("t.date <= ?", [day(end)])), "Net worth at \(point.date)")
        check(point.total == point.assets - point.debt && point.balances.values.reduce(0, +) == point.total)
      }
      check(report.totalChange == report.points.last!.total - report.points.first!.total)
    }
    try checkMonths(netWorth)
    let lastYear = try await report(netWorthID, ["timeFrame": ReportRangePreset.oneYear.timeFrame(earliestMonth: "2000-01").json]).netWorth!
    check(lastYear.start == BudgetDate.month(monthStart(-11)) && lastYear.points.last?.date == currentMonth)
    try checkMonths(lastYear)
    // Year to date, by week: the range override and weekly intervals.
    let weekly = try await report(netWorthID, [
      "timeFrame": ReportRangePreset.yearToDate.timeFrame(earliestMonth: "2000-01").json, "interval": "Weekly",
    ]).netWorth!
    check(weekly.start == "\(currentMonth.prefix(4))-01" && weekly.interval == "Weekly")
    check(weekly.netWorth == (try sum("t.date <= ?", [today])), "Weekly net worth stops today")
    // Filtered to one account.
    let one = try await report("w-nw-one").netWorth!
    check(one.netWorth == (try sum("t.account = ? AND t.date <= ?", [checking.id, throughMonth])))
    check(one.accounts.map(\.id) == [checking.id], "Only the filtered account has a balance")
    check(one.start == "\(currentMonth.prefix(4))-01", "A saved year-to-date range slides to this year")

    // Cash flow: on-budget income and expenses without transfers, this month through today.
    let cashFlowID = widget("cash-flow-card")
    let cashFlow = try await report(cashFlowID, ["detail": .bool(true)]).cashFlow!
    let first = day(monthStart(0))
    let plain = "a.offbudget = 0 AND t.transfer_id IS NULL AND t.date BETWEEN ? AND ?"
    check(cashFlow.income == (try sum("t.amount > 0 AND " + plain, [first, today])), "Income \(cashFlow.income)")
    check(cashFlow.expense == (try sum("t.amount < 0 AND " + plain, [first, today])), "Expenses \(cashFlow.expense)")
    guard let detail = cashFlow.detail else { throw EngineFailure("Cash flow detail missing") }
    check(!detail.isConcise && detail.points.first?.date == BudgetDate.day(monthStart(0)) && detail.points.last?.date == BudgetDate.day(now))
    check(detail.totalIncome == cashFlow.income && detail.totalExpenses == cashFlow.expense)
    check(detail.balance == (try sum("a.offbudget = 0 AND t.date <= ?", [today])), "Running balance \(detail.balance)")
    check(detail.totalTransfers == (try sum("a.offbudget = 0 AND t.transfer_id IS NOT NULL AND t.date BETWEEN ? AND ?", [first, today])))
    // Over three months, by month.
    let year = try await report(cashFlowID, ["detail": .bool(true), "timeFrame": ReportRangePreset.oneYear.timeFrame(earliestMonth: "2000-01").json]).cashFlow!
    check(year.detail?.isConcise == true && year.detail?.points.count == 12, "A year of cash flow is monthly")
    check(year.income == (try sum("t.amount > 0 AND " + plain, [day(monthStart(-11)), today])))

    // Spending: this month against last month, the budget, and the three-month average.
    let spending = try await report(widget("spending-card")).spending!
    check(spending.compare == currentMonth && spending.compareTo == BudgetDate.month(monthStart(-1)))
    let spend = "a.offbudget = 0 AND (c.is_income IS NULL OR c.is_income = 0) AND t.date BETWEEN ? AND ?"
    let spentToday = try sum(spend, [first, today])
    check(spending.days[spending.todayIndex].compare == spentToday, "Spent to date \(String(describing: spending.days[spending.todayIndex].compare))")
    check(spending.todayIndex == min(calendar.component(.day, from: now), 28) - 1)
    check(spending.days.count == 28 && spending.days[27].compare == (now < monthStart(0).addingTimeInterval(27 * 86400) ? nil : spentToday))
    let lastMonthFull = try sum(spend, [day(monthStart(-1)), day(monthEnd(-1))])
    check(spending.days[27].compareTo == lastMonthFull, "Last month \(String(describing: spending.days[27].compareTo))")
    let averaged = try (1...3).map { try sum(spend, [day(monthStart(-$0)), day(monthEnd(-$0))]) }
    check(spending.days[27].average == jsRound(Double(averaged.reduce(0, +)) / 3), "Average \(spending.days[27].average)")
    let budgeted = int(try sql("SELECT IFNULL(SUM(amount), 0) AS total FROM zero_budgets WHERE month = ?",
                               [Int(currentMonth.replacingOccurrences(of: "-", with: ""))!]).first?["total"])
    check(abs(spending.days[27].budget + budgeted) <= 1, "Budget \(spending.days[27].budget) vs \(budgeted)")
    check(spending.difference(.singleMonth) == (spending.days[spending.todayIndex].compareTo ?? 0) - spentToday)

    // Summary: the default dashboard's expense cards, this year through today.
    let yearStart = Int("\(currentMonth.prefix(4))0101")!
    let expenseFilter = "t.amount < 0 AND a.offbudget = 0 AND t.transfer_id IS NULL AND t.date BETWEEN ? AND ?"
    let spent = try sum(expenseFilter, [yearStart, today])
    let total = try await report("w-sum").summary!
    check(total.type == "sum" && Int(total.total!) == spent && total.dividend == spent, "Summary \(String(describing: total.total))")
    let monthly = try await report("w-month").summary!
    let elapsed = Double(calendar.component(.month, from: now) - 1)
      + Double(calendar.component(.day, from: now)) / Double(calendar.range(of: .day, in: .month, for: now)!.count)
    check(abs(monthly.divisor - elapsed) < 1e-9 && Int(monthly.total!) == jsRound(Double(spent) / elapsed))
    let count = int(try sql("""
      SELECT COUNT(*) AS n FROM v_transactions t LEFT JOIN accounts a ON a.id = t.account
      WHERE t.is_parent = 0 AND t.account IS NOT NULL AND \(expenseFilter)
      """, [yearStart, today]).first?["n"])
    let perTransaction = try await report("w-tx").summary!
    check(Int(perTransaction.divisor) == count && Int(perTransaction.total!) == jsRound(Double(spent) / Double(count)))
    let share = try await report("w-pct").summary!
    let income = try sum("t.amount > 0 AND t.date BETWEEN ? AND ?", [yearStart, today])
    check(share.divisor == Double(income) && share.total == Double(jsRound(Double(spent) / Double(income) * 10000)) / 100,
          "Percentage \(String(describing: share.total))")

    // Calendar: a live three-month range of daily income and spending, without transfers,
    // including later this month.
    let cal = try await report("w-cal").calendar!
    check(cal.months.map(\.month) == (-2...0).map { BudgetDate.month(monthStart($0)) }, "\(cal.months.map(\.month))")
    for (offset, month) in zip(-2...0, cal.months) {
      let range = [day(monthStart(offset)), day(monthEnd(offset))]
      check(month.totalExpense == -(try sum("t.amount < 0 AND t.transfer_id IS NULL AND t.date BETWEEN ? AND ?", range)))
      check(month.totalIncome == (try sum("t.amount > 0 AND t.transfer_id IS NULL AND t.date BETWEEN ? AND ?", range)))
      check(month.days.reduce(0) { $0 + $1.expense } == month.totalExpense)
    }
    guard let busiest = cal.months.flatMap(\.days).max(by: { $0.expense < $1.expense }) else {
      throw EngineFailure("Demo calendar has no spending")
    }
    let listed = try await engine.call(
      "reportTransactions", arguments: ["id": "w-cal", "date": .string(busiest.date)], as: [ReportTransaction].self)
    check(listed.allSatisfy { $0.date == busiest.date } && listed.filter { $0.amount < 0 }.reduce(0) { $0 - $1.amount } == busiest.expense,
          "Transactions for \(busiest.date)")

    // Other widgets and removed ones fail clearly.
    var failed = false
    do { _ = try await report("w-custom") } catch {
      failed = error.localizedDescription.contains("Actual web or desktop")
    }
    check(failed, "Custom reports open in Actual")
    failed = false
    do { _ = try await report("no-such-widget") } catch {
      failed = error.localizedDescription.contains("no longer on the dashboard")
    }
    check(failed, "A removed widget reports that it is gone")
    print("PASS: reports dashboard, net worth, cash flow, spending, summary, calendar")
  }
}
