import Foundation

extension EngineSmoke {
  /// Edits every kind of widget on the demo's dashboard and checks what Actual stores and then reports.
  static func reportEditing(data: URL, resources: URL) async throws {
    let engine = try EngineClient(dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    _ = try await engine.call("demo")
    let budget = try await activeBudget(engine)
    func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) {
      precondition(condition, message(), line: line)
    }
    func sql(_ statement: String, _ params: [Any] = []) throws -> [[String: Any]] {
      try query(data: data, resources: resources, budget: budget, statement, params)
    }
    /// The widget's meta as stored.
    func meta(_ id: String) throws -> [String: Any] {
      guard let text = try sql("SELECT meta FROM dashboard WHERE id = ?", [id]).first?["meta"] as? String,
            let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [:] }
      return object
    }
    func settings(_ id: String) async throws -> ReportWidgetSettings {
      try await engine.call("reportSettings", arguments: ["id": .string(id)], as: ReportWidgetSettings.self)
    }
    func save(_ id: String, _ changes: [String: JSONValue]) async throws {
      _ = try await engine.call("saveReportWidget", arguments: ["id": .string(id), "changes": .object(changes)])
    }
    func rejects(_ id: String, _ changes: [String: JSONValue], _ text: String) async -> Bool {
      do { try await save(id, changes) } catch { return error.localizedDescription.contains(text) }
      return false
    }
    func report(_ id: String) async throws -> ReportData {
      try await engine.call("report", arguments: ["id": .string(id), "options": .object(["detail": .bool(true)])], as: ReportData.self)
    }
    func dashboard() async throws -> ReportsDashboard {
      try await engine.call("reportsDashboard", as: ReportsDashboard.self)
    }
    let now = Date()
    let currentMonth = BudgetDate.month(now)
    func month(_ offset: Int) -> String { ReportDate.month(currentMonth, adding: offset) }

    let board = try await dashboard()
    let earliest = board.earliestMonth
    let page = board.pages[0]
    func widget(_ type: String) -> ReportWidget { page.widgets.first { $0.type == type }! }
    let accounts = try await engine.call("overview", as: BudgetOverview.self).accounts
    guard let checking = accounts.first(where: { !$0.offbudget && !$0.closed }) else {
      throw EngineFailure("Demo needs an on-budget account")
    }
    func condition(_ field: String, _ op: String, _ value: JSONValue) -> JSONValue {
      .object(["field": .string(field), "op": .string(op), "value": value, "type": .string(RuleItem.type(of: field))])
    }

    // Net worth: a widget with nothing saved opens with Actual's defaults.
    let netWorthID = widget("net-worth-card").id
    var opened = try await settings(netWorthID)
    check(opened.name == "" && opened.conditions.isEmpty && opened.conditionsOp == "and")
    check(opened.interval == "Monthly" && opened.graphMode == "trend")
    check(opened.timeFrame == ReportTimeFrame(start: month(-5), end: currentMonth, mode: "sliding-window"), "\(String(describing: opened.timeFrame))")
    var range = ReportRangeDraft(opened.timeFrame!, earliestMonth: earliest, oneMonth: false)
    check(range.kind == .preset(.sixMonths), "The default range is Actual's six months")
    check(opened.changes(from: opened).isEmpty, "An untouched editor saves nothing")
    // Everything its page in Actual saves: name, range, filters, interval, and graph.
    var draft = opened
    draft.name = "  Checking only  "
    draft.interval = "Weekly"
    draft.graphMode = "stacked"
    draft.conditions = [RuleItem(raw: ["field": .string("account"), "op": .string("is"), "value": .string(checking.id), "type": .string("id")])]
    range.kind = .preset(.oneYear)
    var changes = draft.changes(from: opened, timeFrame: range.timeFrame(earliestMonth: earliest))
    check(Set(changes.keys) == ["name", "interval", "graphMode", "conditions", "timeFrame"], "\(changes.keys.sorted())")
    try await save(netWorthID, changes)
    var stored = try meta(netWorthID)
    check(stored["name"] as? String == "Checking only" && stored["interval"] as? String == "Weekly" && stored["mode"] as? String == "stacked")
    check((stored["timeFrame"] as? [String: String]) == ["start": month(-11), "end": currentMonth, "mode": "sliding-window"],
          "\(String(describing: stored["timeFrame"]))")
    check((stored["conditions"] as? [[String: Any]])?.first?["value"] as? String == checking.id && stored["conditionsOp"] == nil)
    let netWorth = try await report(netWorthID).netWorth!
    check(netWorth.interval == "Weekly" && netWorth.mode == "stacked" && netWorth.start == month(-11))
    check(netWorth.accounts.map(\.id) == [checking.id], "The saved filter applies")
    check(try await dashboard().pages[0].widgets.first { $0.id == netWorthID }?.title == "Checking only")
    opened = try await settings(netWorthID)
    check(ReportRangeDraft(opened.timeFrame!, earliestMonth: earliest, oneMonth: false).kind == .preset(.oneYear))
    check(opened.conditions.count == 1 && opened.conditions[0].isEditableFilter)
    // A cleared name becomes Actual's default; nothing else changes.
    try await save(netWorthID, ["name": .string("  ")])
    stored = try meta(netWorthID)
    check(stored["name"] as? String == "Net Worth" && stored["interval"] as? String == "Weekly" && stored["conditions"] != nil)
    // The last four months, live: the current month and the three before.
    range.kind = .live
    range.liveMonths = 4
    try await save(netWorthID, ["timeFrame": range.timeFrame(earliestMonth: earliest)!.json])
    opened = try await settings(netWorthID)
    range = ReportRangeDraft(opened.timeFrame!, earliestMonth: earliest, oneMonth: false)
    check(range.kind == .live && range.liveMonths == 4 && opened.timeFrame?.start == month(-3), "\(range)")
    // Settings of other kinds of widget, and unknown ones, are refused.
    check(await rejects(netWorthID, ["showBalance": .bool(false)], "no setting named showBalance"))
    check(await rejects(netWorthID, ["interval": .string("Hourly")], "valid interval"))
    check(await rejects(netWorthID, ["timeFrame": .object(["start": .string(month(0)), "end": .string(month(-2)), "mode": .string("static")])],
                        "start before it ends"))
    check(await rejects(netWorthID, ["timeFrame": .object(["start": .string("soon"), "end": .string(month(0)), "mode": .string("static")])],
                        "valid range"))
    check(try meta(netWorthID)["interval"] as? String == "Weekly", "A refused save changes nothing")

    // Cash flow: this month by default; fixed months and the balance line are saved.
    let cashFlowID = widget("cash-flow-card").id
    opened = try await settings(cashFlowID)
    check(opened.showBalance == true)
    range = ReportRangeDraft(opened.timeFrame!, earliestMonth: earliest, oneMonth: true)
    check(range.kind == .preset(.oneMonth), "\(range)")
    range.kind = .fixed
    range.start = month(-3)
    range.end = month(-1)
    draft = opened
    draft.showBalance = false
    try await save(cashFlowID, draft.changes(from: opened, timeFrame: range.timeFrame(earliestMonth: earliest)))
    stored = try meta(cashFlowID)
    check(stored["showBalance"] as? Bool == false && stored["name"] == nil && stored["conditions"] == nil, "Only what changed is saved")
    check((stored["timeFrame"] as? [String: String]) == ["start": month(-3), "end": month(-1), "mode": "static"])
    let cashFlow = try await report(cashFlowID).cashFlow!
    check(cashFlow.start == month(-3) && cashFlow.end == month(-1) && !cashFlow.showBalance)
    opened = try await settings(cashFlowID)
    range = ReportRangeDraft(opened.timeFrame!, earliestMonth: earliest, oneMonth: true)
    check(range.kind == .fixed && range.start == month(-3) && range.end == month(-1))

    // Spending: the default widget follows the current month until a month is chosen.
    let spendingID = widget("spending-card").id
    opened = try await settings(spendingID)
    check(opened.name == "This Month" && opened.compare == nil && opened.compareTo == nil && opened.timeFrame == nil)
    check(opened.spendingMode == .singleMonth && opened.averageRange == SpendingReport.AverageRange(mode: "last-n-months", months: 3))
    draft = opened
    draft.spendingMode = .average
    draft.averageRange = SpendingReport.AverageRange(mode: "last-n-months", months: 6)
    draft.compare = month(-1)
    changes = draft.changes(from: opened)
    check(Set(changes.keys) == ["spendingMode", "averageRange", "compare"])
    try await save(spendingID, changes)
    stored = try meta(spendingID)
    check(stored["mode"] as? String == "average" && stored["compare"] as? String == month(-1) && stored["name"] as? String == "This Month")
    var spending = try await report(spendingID).spending!
    check(spending.compare == month(-1) && spending.mode == .average && spending.averageRange.months == 6)
    // Back to the current month, compared with a chosen one.
    opened = try await settings(spendingID)
    draft = opened
    draft.compare = nil
    draft.compareTo = month(-2)
    draft.spendingMode = .singleMonth
    draft.averageRange = SpendingReport.AverageRange(mode: "year-to-date")
    try await save(spendingID, draft.changes(from: opened))
    stored = try meta(spendingID)
    check(stored["compare"] == nil && stored["compareTo"] as? String == month(-2))
    check((stored["averageRange"] as? [String: Any])?["mode"] as? String == "year-to-date")
    spending = try await report(spendingID).spending!
    check(spending.compare == currentMonth && spending.compareTo == month(-2) && spending.mode == .singleMonth)
    check(await rejects(spendingID, ["averageRange": .object(["mode": .string("last-n-months"), "months": .number(5)])], "valid average"))
    check(await rejects(spendingID, ["compare": .string("2026-13")], "valid month"))
    check(await rejects(spendingID, ["timeFrame": ReportTimeFrame(start: month(-1), end: month(0), mode: "static").json], "no setting named timeFrame"))

    // Summary: options live in the content JSON, where the font size Actual's default dashboard sets must stay.
    let summaryID = page.widgets[0].id
    opened = try await settings(summaryID)
    check(opened.name == "Total Income (YTD)" && opened.summaryType == "sum" && opened.conditions.count == 3)
    check(ReportRangeDraft(opened.timeFrame!, earliestMonth: earliest, oneMonth: true).kind == .preset(.yearToDate))
    // Its default filters include ones this app's editor offers, and its on-budget account filter.
    check(opened.conditions.allSatisfy(\.isEditableFilter), "\(opened.conditions.map(\.raw))")
    let before = try meta(summaryID)
    draft = opened
    draft.summaryType = "percentage"
    draft.divisorConditions = [RuleItem(raw: ["field": .string("amount"), "op": .string("gt"), "value": .number(0), "type": .string("number")])]
    draft.divisorAllTimeDateRange = true
    changes = draft.changes(from: opened)
    check(Set(changes.keys) == ["summaryType", "divisorConditions", "divisorAllTimeDateRange"])
    try await save(summaryID, changes)
    stored = try meta(summaryID)
    let content = try JSONSerialization.jsonObject(with: Data((stored["content"] as? String ?? "").utf8)) as? [String: Any] ?? [:]
    check(content["type"] as? String == "percentage" && (content["fontSize"] as? NSNumber)?.intValue == 20, "\(content)")
    check(content["divisorAllTimeDateRange"] as? Bool == true && content["divisorConditionsOp"] as? String == "and")
    check((content["divisorConditions"] as? [[String: Any]])?.count == 1)
    check((stored["timeFrame"] as? [String: String]) == (before["timeFrame"] as? [String: String]), "An unchanged range stays as saved")
    check((stored["conditions"] as? [[String: Any]])?.count == 3)
    let share = try await report(summaryID).summary!
    check(share.type == "percentage" && share.divisorAllTime && share.divisor > 0)
    opened = try await settings(summaryID)
    check(opened.summaryType == "percentage" && opened.divisorAllTimeDateRange == true && opened.divisorConditions?.count == 1)
    // All time keeps the first month with transactions.
    try await save(summaryID, ["timeFrame": ReportRangePreset.allTime.timeFrame(earliestMonth: earliest).json, "summaryType": .string("avgPerMonth")])
    stored = try meta(summaryID)
    check((stored["timeFrame"] as? [String: String])?["mode"] == "full" && (stored["timeFrame"] as? [String: String])?["start"] == earliest)
    opened = try await settings(summaryID)
    check(ReportRangeDraft(opened.timeFrame!, earliestMonth: earliest, oneMonth: true).kind == .preset(.allTime))
    check(opened.summaryType == "avgPerMonth" && opened.divisorConditions?.count == 1, "The divisor's filters stay for later")
    check(await rejects(summaryID, ["summaryType": .string("median")], "valid summary"))

    // Calendar: a range of days and settings this app does not know stay as saved when only filters change.
    _ = try sql(
      "INSERT INTO dashboard (id, type, width, height, x, y, meta, tombstone, dashboard_page_id) VALUES ('w-cal', 'calendar-card', 8, 4, 0, 30, ?, 0, ?)",
      [#"{"name":"Cal","timeFrame":{"start":"2024-01-01","end":"2024-03-31","mode":"sliding-window"},"conditions":[{"field":"transfer","op":"is","value":false},{"field":"date","op":"is","value":"2024-01","options":{"month":true}},{"field":"id","op":"oneOf","value":["a"],"customName":"Selected transactions"}],"conditionsOp":"and","futureOption":7}"#,
       page.id])
    opened = try await settings("w-cal")
    range = ReportRangeDraft(opened.timeFrame!, earliestMonth: earliest, oneMonth: true)
    check(range.kind == .saved && range.timeFrame(earliestMonth: earliest) == nil, "A range of days is kept unless another is chosen")
    check(opened.timeFrame?.end == BudgetDate.day(now) && ReportDate.describe(opened.timeFrame!) == "Last 91 days",
          "\(ReportDate.describe(opened.timeFrame!))")
    check(opened.conditions.map(\.isEditableFilter) == [true, false, false], "Month dates and named filters are kept, not edited")
    check(opened.conditions[2].customName == "Selected transactions")
    draft = opened
    draft.conditions.remove(at: 1)
    draft.conditions.append(.condition(field: "category_group"))
    draft.conditionsOp = "or"
    changes = draft.changes(from: opened, timeFrame: range.timeFrame(earliestMonth: earliest))
    check(Set(changes.keys) == ["conditions", "conditionsOp"])
    try await save("w-cal", changes)
    stored = try meta("w-cal")
    check((stored["futureOption"] as? NSNumber)?.intValue == 7, "Unknown settings survive a save")
    check((stored["timeFrame"] as? [String: String]) == ["start": "2024-01-01", "end": "2024-03-31", "mode": "sliding-window"])
    let kept = stored["conditions"] as? [[String: Any]] ?? []
    check(kept.map { $0["field"] as? String } == ["transfer", "id", "category_group"] && kept[1]["customName"] as? String == "Selected transactions")
    check(stored["conditionsOp"] as? String == "or")
    check(try await report("w-cal").calendar != nil, "The report still runs with the saved filters")
    // Filters Actual cannot run are refused, naming the filter.
    check(await rejects("w-cal", ["conditions": .array([condition("transfer", "is", .bool(false)), condition("date", "is", .string("someday"))])],
                        "Filter 2: Invalid date format"))
    check(await rejects("w-cal", ["conditions": .array([condition("amount", "contains", .string("x"))])], "Filter 1:"))
    check(await rejects("w-cal", ["conditionsOp": .string("xor")], "all or any"))
    // Removing every filter counts transfers again.
    try await save("w-cal", ["conditions": .array([])])
    check((try meta("w-cal")["conditions"] as? [Any])?.isEmpty == true)

    // Text: Markdown and its position; it has no name or filters.
    let textID = widget("markdown-card").id
    opened = try await settings(textID)
    check(opened.content?.contains("Dashboard Tips") == true && opened.textAlign == "left" && opened.name == "")
    draft = opened
    draft.content = "# Notes\n\nPay rent on the **1st**."
    draft.textAlign = "center"
    try await save(textID, draft.changes(from: opened))
    let text = try await dashboard().pages[0].widgets.first { $0.id == textID }
    check(text?.content == "# Notes\n\nPay rent on the **1st**." && text?.textAlign == "center")
    check(await rejects(textID, ["name": .string("Tips")], "no setting named name"))
    check(await rejects(textID, ["textAlign": .string("justify")], "valid alignment"))

    // Other widgets, and removed ones, open in Actual.
    _ = try sql(
      "INSERT INTO dashboard (id, type, width, height, x, y, meta, tombstone, dashboard_page_id) VALUES ('w-custom', 'custom-report', 4, 2, 0, 40, ?, 0, ?)",
      [#"{"id":"missing-report"}"#, page.id])
    var failed = false
    do { _ = try await settings("w-custom") } catch { failed = error.localizedDescription.contains("Actual web or desktop") }
    check(failed, "Custom reports are edited in Actual")
    check(await rejects("w-custom", ["name": .string("Mine")], "Actual web or desktop"))
    check(await rejects("no-such-widget", ["name": .string("Mine")], "no longer on the dashboard"))
    print("PASS: report widget editing for net worth, cash flow, spending, summary, calendar, and text")
  }
}
