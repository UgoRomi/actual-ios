import Foundation

/// Runs described targets through Apple's on-device model and checks the targets it produces.
/// The model is deterministic for a given description, but its answers change with the model's
/// version, so this reports every case and fails only when a case is wrong.
@main struct GoalDescriptionEvaluation {
    struct Case {
        let text: String
        let expect: ([TargetTemplate]) -> String?
    }

    static func main() async {
        if let reason = GoalDescription.unavailableReason {
            print("SKIP: \(reason)")
            return
        }
        let month = BudgetDate.month(Date())
        let year = Int(month.prefix(4)) ?? 2026
        let nextJanuary = "\(year + 1)-01"
        let nextDecember = month <= "\(year)-12" ? "\(year)-12" : "\(year + 1)-12"
        let context = GoalDescription.Context(
            month: month, currency: "EUR",
            schedules: [TargetSchedule(id: "sched-rent", name: "Rent"), TargetSchedule(id: "sched-car", name: "Car Insurance")],
            incomeCategories: [IncomeCategory(id: "inc-salary", name: "Salary"), IncomeCategory(id: "inc-bonus", name: "Bonus")])

        func one(_ templates: [TargetTemplate], _ kind: TargetTemplate.Kind) -> TargetTemplate? {
            templates.count == 1 && templates[0].kind == kind ? templates[0] : nil
        }
        func by(_ amount: Int, _ month: String, yearly: Bool) -> ([TargetTemplate]) -> String? {
            { templates in
                guard let t = one(templates, .by) else { return "expected one save by date" }
                guard t.amount == amount else { return "amount \(t.amount)" }
                guard t.string("month") == month else { return "month \(t.string("month") ?? "nil"), expected \(month)" }
                guard (t.bool("annual") && t.int("repeat") == 1) == yearly, t.repeats == yearly else { return "repeat \(t.fields)" }
                return nil
            }
        }
        func fixed(_ amount: Int, _ unit: String, _ count: Int = 1) -> ([TargetTemplate]) -> String? {
            { templates in
                guard let t = one(templates, .fixed) else { return "expected one fixed amount" }
                guard t.amount == amount, t.periodUnit == unit, t.periodCount == count else { return "\(t.fields)" }
                return nil
            }
        }

        let cases: [Case] = [
            Case(text: "I want to have 150€ budgeted by each January for a bill. The bill may be less than 150, and if so, next year refill up to 150.",
                 expect: by(15_000, nextJanuary, yearly: true)),
            Case(text: "150 for the insurance every January", expect: by(15_000, nextJanuary, yearly: true)),
            Case(text: "Save 1200 by December for a new phone", expect: by(120_000, nextDecember, yearly: false)),
            Case(text: "Save 400 by December for Christmas presents, every year", expect: by(40_000, nextDecember, yearly: true)),
            Case(text: "Put 50 a month into this category", expect: fixed(5_000, "month")),
            Case(text: "Budget 25 every week", expect: fixed(2_500, "week")),
            Case(text: "Add 600 once a year", expect: fixed(60_000, "year")),
            Case(text: "€40 every two weeks for haircuts", expect: fixed(4_000, "week", 2)),
            Case(text: "Save 10% of my salary", expect: { templates in
                guard let t = one(templates, .percentage) else { return "expected one percentage" }
                guard t.double("percent") == 10 else { return "percent \(t.double("percent") ?? -1)" }
                guard t.string("category") == "inc-salary" else { return "category \(t.string("category") ?? "nil")" }
                return nil
            }),
            Case(text: "Set aside 15 percent of all my income", expect: { templates in
                guard let t = one(templates, .percentage) else { return "expected one percentage" }
                guard t.double("percent") == 15, t.string("category") == "all income" else { return "\(t.fields)" }
                return nil
            }),
            Case(text: "Budget what I spent on average over the last 6 months", expect: { templates in
                guard let t = one(templates, .historical), t.type == "average" else { return "expected one average" }
                return t.int("numMonths") == 6 ? nil : "months \(t.int("numMonths") ?? -1)"
            }),
            Case(text: "Same as last month", expect: { templates in
                guard let t = one(templates, .historical), t.type == "copy" else { return "expected one copy" }
                return t.int("lookBack") == 1 ? nil : "lookBack \(t.int("lookBack") ?? -1)"
            }),
            Case(text: "Cover my rent schedule", expect: { templates in
                guard let t = one(templates, .schedule) else { return "expected one schedule" }
                return t.string("scheduleId") == "sched-rent" ? nil : "schedule \(t.fields)"
            }),
            Case(text: "Save up for the car insurance payment", expect: { templates in
                guard let t = one(templates, .schedule) else { return "expected one schedule" }
                return t.string("scheduleId") == "sched-car" ? nil : "schedule \(t.fields)"
            }),
            Case(text: "Keep 300 in here and top it back up every month", expect: { templates in
                guard templates.count == 2, let cap = templates.first(where: { $0.kind == .limit }),
                      templates.contains(where: { $0.kind == .refill }) else { return "expected cap and refill: \(templates.map(\.type))" }
                return cap.amount == 30_000 ? nil : "cap \(cap.amount)"
            }),
            // A cap alone is not a valid target in Actual, so it becomes a cap that is refilled.
            Case(text: "Never budget more than 200 in this category", expect: { templates in
                guard templates.count == 2, let cap = templates.first(where: { $0.kind == .limit }),
                      templates.contains(where: { $0.kind == .refill }) else { return "expected cap and refill: \(templates.map(\.type))" }
                return cap.amount == 20_000 ? nil : "cap \(cap.amount)"
            }),
            Case(text: "Give this category whatever is left over", expect: { templates in
                one(templates, .remainder) == nil ? "expected whatever is left: \(templates.map(\.type))" : nil
            }),
            Case(text: "I'm saving 5000 for a new laptop, no deadline", expect: { templates in
                guard let t = one(templates, .goal) else { return "expected one goal: \(templates.map(\.type))" }
                return t.amount == 500_000 ? nil : "goal \(t.amount)"
            }),
            Case(text: "100 a month, but never let the balance go above 500", expect: { templates in
                guard templates.count == 2, let fixed = templates.first(where: { $0.kind == .fixed }),
                      let cap = templates.first(where: { $0.kind == .limit }) else { return "expected fixed and cap: \(templates.map(\.type))" }
                return fixed.amount == 10_000 && cap.amount == 50_000 ? nil : "\(fixed.amount) \(cap.amount)"
            }),
            // Either reading is right: 900 every third month, or 300 a month toward each bill.
            Case(text: "I need 900 every 3 months for the water bill", expect: { templates in
                guard templates.count == 1, templates[0].amount == 90_000 else { return "expected one 900 target: \(templates.map(\.type))" }
                let t = templates[0]
                if t.kind == .fixed { return t.periodUnit == "month" && t.periodCount == 3 ? nil : "period \(t.fields)" }
                if t.kind == .by { return !t.bool("annual") && t.int("repeat") == 3 ? nil : "repeat \(t.fields)" }
                return "expected fixed or save by date: \(t.type)"
            }),
            Case(text: "Metti da parte 80 euro al mese per la palestra", expect: fixed(8_000, "month")),
        ]

        var failures = 0
        for (index, item) in cases.enumerated() {
            do {
                let templates = try await GoalDescription.describe(item.text, context: context)
                let summaries = templates.map { $0.summary(currency: "EUR", income: context.incomeCategories) }
                if let problem = item.expect(templates) {
                    failures += 1
                    print("FAIL \(index + 1): \(item.text)\n  got: \(summaries)\n  \(problem)")
                } else {
                    print("ok   \(index + 1): \(item.text)\n  → \(summaries.joined(separator: " + "))")
                }
            } catch {
                failures += 1
                print("FAIL \(index + 1): \(item.text)\n  error: \(error.localizedDescription)")
            }
        }
        print(failures == 0 ? "PASS: \(cases.count) described targets" : "FAILED: \(failures) of \(cases.count) described targets")
        if failures > 0 { exit(1) }
    }
}
