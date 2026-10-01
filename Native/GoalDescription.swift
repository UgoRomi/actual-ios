import Foundation
import FoundationModels

/// Turns a description such as “150 for the insurance bill every January” into
/// targets, using Apple's on-device model. Nothing leaves the device. The model
/// fills a fixed form; the app then builds Actual's templates from it, so the
/// result is always something the editor and Actual's parser can read.
enum GoalDescription {
    /// Why the on-device model cannot be used, in the words the editor shows.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This device does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in Settings to describe targets."
        case .unavailable(.modelNotReady): "Apple Intelligence is still downloading its model."
        case .unavailable: "Apple Intelligence is not available."
        }
    }
    static var isAvailable: Bool { unavailableReason == nil }

    /// What the budget offers the description can refer to.
    struct Context {
        var month: String
        var currency: String
        var schedules: [TargetSchedule]
        var incomeCategories: [IncomeCategory]
    }

    /// The kinds the model may choose; each maps to one of the editor's kinds.
    @Generable(description: "The kind of budget target")
    enum Kind: String, CaseIterable {
        case fixedAmount, saveByDate, percentOfIncome, averageOfPastMonths, copyPreviousMonth, coverSchedule
        case balanceCap, refillToCap, whateverIsLeft, longTermGoal
    }

    /// One target as the model describes it. Fields a kind does not use are left out.
    @Generable(description: "One budget target for the category")
    struct Target {
        @Guide(description: "Which kind of target this is")
        var kind: Kind
        @Guide(description: "The amount of money, as a plain number in the budget's currency. 0 when the kind has no amount.")
        var amount: Double
        @Guide(description: "fixedAmount only: how often to add the amount, such as week, month, year, 2 weeks, or 3 months")
        var every: String?
        @Guide(description: "saveByDate only: the month the money must be ready by, as yyyy-MM, after today")
        var byMonth: String?
        @Guide(description: "saveByDate only: true when it comes back every year, such as every January; omit for a one-time purchase")
        var repeatsYearly: Bool?
        @Guide(description: "saveByDate only: when it repeats every N months instead of yearly, N")
        var repeatsEveryMonths: Int?
        @Guide(description: "percentOfIncome only: the percentage, 1 to 100; amount is then 0")
        var percent: Double?
        @Guide(description: "percentOfIncome only: the one income category the person names, exactly as listed. Omit for all income or when none is named.")
        var incomeCategory: String?
        @Guide(description: "averageOfPastMonths: how many past months to average. copyPreviousMonth: how many months ago the month to copy is; last month is 1")
        var months: Int?
        @Guide(description: "coverSchedule only: the schedule's name")
        var scheduleName: String?
        @Guide(description: "balanceCap only: true when money already over the cap should stay in the category")
        var keepExcessOverCap: Bool?
        @Guide(description: "Anything the person said that the fields cannot hold, in a few words. Usually omitted.")
        var note: String?
    }

    /// The model's answer. A pair rather than a list: Apple's guardrails refuse a
    /// list holding a periodic amount ("25 every week"), while a pair passes.
    @Generable(description: "The targets a description asks for")
    struct Targets {
        @Guide(description: "The target the description asks for")
        var target: Target
        @Guide(description: "A second target only when the person asks for two things, such as a cap and a refill, or an amount and a cap")
        var alsoTarget: Target?
    }

    static func instructions(_ context: Context) -> String {
        let schedules = context.schedules.map(\.name).joined(separator: "; ")
        let income = context.incomeCategories.map(\.name).joined(separator: "; ")
        let month = context.month
        let nextJanuary = TargetTemplate.month(String(month.prefix(4)) + "-01", adding: 12)
        return """
        You turn a person's description of how to budget one category into targets for the Actual Budget app.
        Today's month is \(month). Amounts are in \(context.currency.isEmpty ? "the budget's currency" : context.currency); write them as plain numbers.

        Choose kinds by these rules:
        - A set amount every day, week, month, or year ("50 a month", "600 once a year"), with no deadline: fixedAmount.
        - Money needed by a month, including a bill due each year ("every January", "by December"): saveByDate. byMonth is the next such month after today, so the soonest one. Set repeatsYearly when it comes back every year: "every year", "each January", "every December", a yearly bill. A one-time purchase does not repeat. saveByDate already refills: after the money is spent it saves toward the next due month, so add nothing else for it.
        - A share of income: percentOfIncome.
        - Based on what was spent before: averageOfPastMonths, or copyPreviousMonth to repeat a past month.
        - Paying a schedule in this budget: coverSchedule.
        - A limit on how much the category may hold ("up to", "no more than"): balanceCap. Add refillToCap only when they want it topped back up to the cap each month.
        - Whatever money is left after other targets: whateverIsLeft.
        - A large amount to save with no date and no rhythm at all: longTermGoal.
        Use one target unless the person asks for two things: an amount each month plus a limit on the balance is a fixedAmount and a balanceCap; keeping a balance topped up is a balanceCap and a refillToCap. Never invent an amount, schedule, or income category the person did not say. When the person names one of the schedules listed below, use coverSchedule for it. Leave out fields the kind does not use.

        Schedules in this budget: \(schedules.isEmpty ? "none" : schedules).
        Income categories: \(income.isEmpty ? "none" : income).

        Examples:
        "200 for the property tax every January; if the bill is less, refill to 200 next year" → one saveByDate, amount 200, byMonth \(nextJanuary), repeatsYearly true.
        "put 50 a month into groceries" → one fixedAmount, amount 50, every month.
        "save 10% of my paycheck" → percentOfIncome, percent 10, amount 0, no incomeCategory.
        """
    }

    /// Reads targets from a description. Throws the model's errors with messages for the editor.
    static func describe(_ text: String, context: Context) async throws -> [TargetTemplate] {
        // The description is the person's own budgeting words, which the default
        // guardrails sometimes refuse ("put 50 a month into this category").
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: instructions(context))
        let response: LanguageModelSession.Response<Targets>
        do {
            response = try await session.respond(
                to: text, generating: Targets.self, options: GenerationOptions(samplingMode: .greedy))
        } catch {
            throw DescriptionError(error)
        }
        let answer = response.content
        var targets = [answer.target]
        // The model sometimes adds a second target from nowhere: a cap with an
        // unsaid number, or a schedule the person never mentioned.
        if let also = answer.alsoTarget, grounded(also, in: text, context: context) { targets.append(also) }
        var templates = targets.map { template($0, context: context, description: text) }
        // Actual accepts a balance cap only beside something that budgets funds. A cap
        // on its own means "keep it topped up to this", which is a refill.
        if templates.contains(where: { $0.kind == .limit }), templates.allSatisfy(\.isOption) {
            templates.append(TargetTemplate(kind: .refill))
        }
        return templates
    }

    /// Builds the editor's template from the model's form. Amounts use two decimal places, as the editor does.
    /// Only an income category the description names is used; the model likes to pick one anyway.
    static func template(_ target: Target, context: Context, description: String = "") -> TargetTemplate {
        let minorUnits = Int((target.amount * 100).rounded())
        var template: TargetTemplate
        switch target.kind {
        case .fixedAmount:
            template = TargetTemplate(kind: .fixed)
            template.amount = minorUnits
            let (count, unit) = period(target.every)
            template.periodUnit = unit
            template.periodCount = count
        case .saveByDate:
            template = TargetTemplate(kind: .by)
            template.amount = minorUnits
            var month = target.byMonth.flatMap { validMonth($0) } ?? TargetTemplate.month(context.month, adding: 12)
            // The next such month: a month already passed means next year's.
            while month < context.month { month = TargetTemplate.month(month, adding: 12) }
            let every = target.repeatsYearly == true ? 12 : max(0, target.repeatsEveryMonths ?? 0)
            if every > 0 {
                // A repeating target is for its soonest due month; the model sometimes
                // names a later year, and Actual would then save over the longer stretch.
                while TargetTemplate.month(month, adding: -every) >= context.month {
                    month = TargetTemplate.month(month, adding: -every)
                }
                template.repeats = true
                template.set("annual", .bool(every == 12))
                template.set("repeat", .number(every == 12 ? 1 : every))
            } else {
                template.repeats = false
            }
            template.set("month", .string(month))
        case .percentOfIncome:
            template = TargetTemplate(kind: .percentage)
            // The model sometimes writes the percentage as the amount.
            var percent = target.percent ?? 0
            if percent <= 0, target.amount > 0, target.amount <= 100 { percent = target.amount }
            template.set("percent", json(min(100, max(0, percent))))
            let name = target.incomeCategory?.lowercased() ?? ""
            let words = description.lowercased()
            let match = context.incomeCategories.first { $0.name.lowercased() == name }
                ?? context.incomeCategories.first { !name.isEmpty && $0.name.lowercased().contains(name) }
            let named = match.map { words.contains($0.name.lowercased()) } ?? false
            template.set("category", .string(named ? match!.id : "all income"))
        case .averageOfPastMonths:
            template = TargetTemplate(kind: .historical)
            template.set("numMonths", .number(max(1, target.months ?? 3)))
        case .copyPreviousMonth:
            template = TargetTemplate(kind: .historical)
            template.set("type", "copy")
            template.set("numMonths", nil)
            // "Last month" names no number; the model has answered 12 for it.
            let said = description.contains { $0.isNumber }
            template.set("lookBack", .number(said ? max(1, target.months ?? 1) : 1))
        case .coverSchedule:
            template = TargetTemplate(kind: .schedule)
            let name = target.scheduleName?.lowercased() ?? ""
            let match = context.schedules.first { $0.name.lowercased() == name }
                ?? context.schedules.first { !name.isEmpty && $0.name.lowercased().contains(name) }
                ?? context.schedules.first { !name.isEmpty && name.contains($0.name.lowercased()) }
            if let match {
                template.set("scheduleId", .string(match.id))
                template.set("name", .string(match.name))
            } else if let name = target.scheduleName {
                template.set("name", .string(name))
            }
        case .balanceCap:
            template = TargetTemplate(kind: .limit)
            template.amount = minorUnits
            template.set("hold", .bool(target.keepExcessOverCap == true))
        case .refillToCap:
            template = TargetTemplate(kind: .refill)
        case .whateverIsLeft:
            template = TargetTemplate(kind: .remainder)
        case .longTermGoal:
            template = TargetTemplate(kind: .goal)
            template.amount = minorUnits
        }
        if let note = target.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            template.note = note
        }
        return template
    }

    /// Whether a second target comes from the description: its amount or schedule
    /// is written there, or it is the refill that pairs with a cap.
    static func grounded(_ target: Target, in text: String, context: Context) -> Bool {
        let words = text.lowercased()
        switch target.kind {
        case .refillToCap, .whateverIsLeft: return true
        case .coverSchedule:
            let name = target.scheduleName?.lowercased() ?? ""
            return !name.isEmpty && (words.contains(name) || context.schedules.contains { words.contains($0.name.lowercased()) && name.contains($0.name.lowercased()) })
        case .percentOfIncome: return words.contains("%") || words.contains("percent") || words.contains("per cent")
        case .averageOfPastMonths, .copyPreviousMonth: return words.contains("average") || words.contains("last month") || words.contains("previous")
        case .fixedAmount, .saveByDate, .balanceCap, .longTermGoal: return target.amount > 0 && mentions(target.amount, in: text)
        }
    }

    /// Whether the description writes the amount, as 500, 500.00, 500,00, or 1,500.
    static func mentions(_ amount: Double, in text: String) -> Bool {
        let digits = text.filter { $0.isNumber || $0 == "." || $0 == "," }
        let whole = String(Int(amount.rounded(.towardZero)))
        let variants = [whole, whole + ".", whole + ","] + (amount.rounded() == amount ? [] : [String(format: "%.2f", amount), String(format: "%.2f", amount).replacingOccurrences(of: ".", with: ",")])
        if variants.contains(where: { digits.contains($0) }) { return true }
        // Grouped thousands: 1,500 or 1.500.
        return whole.count > 3 && digits.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: ".", with: "").contains(whole)
    }

    /// Reads "month", "2 weeks", "every three months", "weekly", or "fortnight" as a count and unit.
    static func period(_ text: String?) -> (count: Int, unit: String) {
        let words = (text ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let numbers = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "ten": 10, "twelve": 12]
        var count = 1
        var unit = "month"
        for word in words {
            if let number = Int(word) ?? numbers[word] { count = number }
            else if word.hasPrefix("da") { unit = "day" }
            else if word.hasPrefix("week") { unit = "week" }
            else if word.hasPrefix("month") { unit = "month" }
            else if word.hasPrefix("year") || word.hasPrefix("annual") { unit = "year" }
            else if word.hasPrefix("fortnight") || word == "biweekly" { unit = "week"; count = 2 }
        }
        return (max(1, min(366, count)), unit)
    }

    /// `yyyy-MM`, which the model usually writes; also accepts a day or a bare year.
    static func validMonth(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if BudgetDate.date(trimmed) != nil { return String(trimmed.prefix(7)) }
        if BudgetDate.date(trimmed + "-01") != nil { return trimmed }
        if trimmed.count == 4, Int(trimmed) != nil { return trimmed + "-01" }
        return nil
    }

    private static func json(_ value: Double) -> JSONValue {
        value.rounded() == value ? .number(Int(value)) : .double(value)
    }

    /// The model's errors, in the words the editor shows.
    struct DescriptionError: LocalizedError {
        static let declined = "Apple Intelligence declined this description. Try rewording it."
        static let language = "Describe the target in a language Apple Intelligence supports."
        static let long = "Keep the description shorter."
        static let busy = "Apple Intelligence is busy. Try again in a moment."
        static let refused = "Apple Intelligence could not turn this into targets. Try saying the amount and when it is needed."
        static let unreadable = "Apple Intelligence could not read this description."

        let errorDescription: String?
        init(_ error: any Error) {
            if #available(iOS 27, macOS 27, *), let error = error as? LanguageModelError {
                errorDescription = switch error {
                case .guardrailViolation: Self.declined
                case .unsupportedLanguageOrLocale: Self.language
                case .contextSizeExceeded: Self.long
                case .rateLimited, .timeout: Self.busy
                case .refusal: Self.refused
                default: error.errorDescription ?? Self.unreadable
                }
            } else if let error = error as? LanguageModelSession.GenerationError {
                // What iOS 26 throws; iOS 27 replaced it with LanguageModelError.
                errorDescription = switch error {
                case .guardrailViolation: Self.declined
                case .unsupportedLanguageOrLocale: Self.language
                case .exceededContextWindowSize: Self.long
                case .rateLimited: Self.busy
                case .refusal: Self.refused
                default: error.errorDescription ?? Self.unreadable
                }
            } else {
                errorDescription = error.localizedDescription
            }
        }
    }
}
