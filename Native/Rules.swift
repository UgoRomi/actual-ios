import Foundation

/// A transaction rule, as Actual stores it: conditions, then actions.
struct Rule: Decodable, Identifiable, Sendable {
    var id: String
    /// "pre" or "post"; nil runs in the default stage.
    var stage: String?
    /// "and" (all conditions) or "or" (any).
    var conditionsOp: String
    var conditions: [RuleItem]
    var actions: [RuleItem]

    /// Schedules own their rules; Actual edits them with the schedule.
    var isSchedule: Bool { actions.contains { $0.op == "link-schedule" } }
    /// Whether every part is one this app's editor offers, as Actual's editor does.
    var isEditable: Bool { !isSchedule && conditions.allSatisfy(\.isEditableCondition) && actions.allSatisfy(\.isEditableAction) }

    /// How many transactions the rule splits a match into; 0 when it does not split.
    var splitCount: Int { actions.map(\.splitIndex).max() ?? 0 }

    /// The indices of a split's actions: 0 for those applied before splitting.
    func actionIndices(split: Int) -> [Int] { actions.indices.filter { actions[$0].splitIndex == split } }

    /// As Actual's editor adds an action: the first field the split does not set yet.
    mutating func addAction(split: Int) {
        let used = Set(actions.filter { $0.splitIndex == split }.map(\.field))
        let fields = RuleItem.actionFields(split: split)
        actions.append(.action(field: fields.first { !used.contains($0) } ?? "category", split: split))
    }

    /// As Actual's "Split into multiple transactions": a new split takes an equal part of the remainder.
    mutating func addSplit() {
        let split = splitCount + 1
        actions.append(.splitAmount(split: split))
        addAction(split: split)
    }

    /// Removes a split and its actions, renumbering the splits after it.
    mutating func removeSplit(_ split: Int) {
        actions.removeAll { $0.splitIndex == split }
        for index in actions.indices where actions[index].splitIndex > split {
            actions[index].splitIndex -= 1
        }
    }

    static func new() -> Rule {
        Rule(id: "", stage: nil, conditionsOp: "and",
             conditions: [RuleItem.condition(field: "payee")], actions: [RuleItem.action(field: "category")])
    }

    var json: [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "stage": stage.map { .string($0) } ?? .null, "conditionsOp": .string(conditionsOp),
            "conditions": .array(conditions.map { .object($0.raw) }), "actions": .array(actions.map { .object($0.raw) }),
        ]
        if !id.isEmpty { fields["id"] = .string(id) }
        return fields
    }
}

/// A transaction a rule's conditions match, as the rule editor lists them.
struct RuleMatch: Decodable, Identifiable, Sendable, Equatable {
    let id: String
    let date: String
    let amount: Int
    let payeeId: String?
    let accountId: String
    let categoryId: String?
    let notes: String
}

/// A rule condition or action, kept as Actual's JSON so settings this app does not edit survive saving.
struct RuleItem: Decodable, Sendable, Equatable, Identifiable {
    var raw: [String: JSONValue]
    /// For lists only; not saved.
    var id = UUID()

    init(raw: [String: JSONValue]) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try [String: JSONValue](from: decoder) }
    static func == (a: RuleItem, b: RuleItem) -> Bool { a.raw == b.raw }

    var field: String { if case .string(let value) = raw["field"] { value } else { "" } }
    var op: String { if case .string(let value) = raw["op"] { value } else { "" } }
    var value: JSONValue { raw["value"] ?? .null }
    var options: [String: JSONValue] { if case .object(let value) = raw["options"] { value } else { [:] } }

    /// The split an action applies to; 0 for the transaction itself.
    var splitIndex: Int {
        get { if case .number(let split) = options["splitIndex"] { split } else { 0 } }
        set {
            var options = options
            options["splitIndex"] = .number(newValue)
            raw["options"] = .object(options)
        }
    }

    /// How a split's amount is allocated: "fixed-amount", "fixed-percent", or "remainder".
    var splitMethod: String { if case .string(let method) = options["method"] { method } else { "" } }

    /// A field's type, as Actual's FIELD_INFO defines it.
    static func type(of field: String) -> String {
        switch field {
        case "payee", "account", "category", "category_group": "id"
        case "imported_payee", "payee_name", "notes": "string"
        case "amount": "number"
        case "date": "date"
        default: "boolean"
        }
    }

    /// Condition fields Actual's editor offers; amount also has inflow and outflow variants.
    static let conditionFields = ["imported_payee", "payee", "account", "category", "category_group", "date", "notes",
                                  "amount", "cleared"]
    static let actionFields = ["category", "payee", "payee_name", "notes", "cleared", "account", "date", "amount"]
    /// Fields only the whole transaction has, which its splits cannot set.
    static let parentOnlyFields: Set<String> = ["amount", "cleared", "account", "date"]

    /// The fields an action can set, as Actual's editor offers them. Like Actual without its
    /// templating feature, payee name is offered only to an action that already sets it.
    static func actionFields(split: Int, current: String? = nil) -> [String] {
        actionFields.filter { (split == 0 || !parentOnlyFields.contains($0)) && ($0 != "payee_name" || $0 == current) }
    }

    /// Actual's split allocation methods, less formulas.
    static let splitMethods = ["fixed-amount", "fixed-percent", "remainder"]
    /// Fields Actual's filter menu offers for reports (FiltersMenu.tsx); its category filter also matches by group.
    static let filterFields = ["date", "account", "payee", "notes", "category", "category_group", "amount",
                               "cleared", "reconciled", "transfer"]

    /// Actual's valid operators for a condition field (shared/rules.ts), less tags.
    static func ops(for field: String) -> [String] {
        switch field {
        case "payee", "category", "category_group", "imported_payee":
            ["is", "contains", "matches", "oneOf", "isNot", "doesNotContain", "notOneOf"]
        case "account": ["is", "contains", "matches", "oneOf", "isNot", "doesNotContain", "notOneOf", "onBudget", "offBudget"]
        case "notes": ["is", "contains", "matches", "isNot", "doesNotContain", "hasTags", "hasAnyTag"]
        case "amount": ["is", "isapprox", "isbetween", "gt", "gte", "lt", "lte"]
        case "date": ["is", "isapprox", "gt", "gte", "lt", "lte"]
        default: ["is"]
        }
    }

    static func condition(field: String, op: String? = nil) -> RuleItem {
        let op = op ?? ops(for: field)[0]
        return RuleItem(raw: ["field": .string(field), "op": .string(op), "type": .string(type(of: field)),
                              "value": defaultValue(field: field, op: op)])
    }

    static func action(field: String, split: Int = 0) -> RuleItem {
        RuleItem(raw: ["field": .string(field), "op": .string("set"), "type": .string(type(of: field)),
                       "value": defaultValue(field: field, op: "set"), "options": .object(["splitIndex": .number(split)])])
    }

    /// A split's share of the amount, as Actual's editor starts one: an equal part of the remainder.
    static func splitAmount(split: Int, method: String = "remainder") -> RuleItem {
        var item = RuleItem(raw: ["op": .string("set-split-amount"),
                                  "options": .object(["splitIndex": .number(split), "method": .string(method)])])
        if method != "remainder" { item.raw["value"] = .number(0) }
        return item
    }

    static func defaultValue(field: String, op: String) -> JSONValue {
        if ["oneOf", "notOneOf"].contains(op) { return .array([]) }
        if ["onBudget", "offBudget"].contains(op) { return .null }
        // As Actual's editor starts a condition, with nothing chosen, which its validation reports.
        if op != "set", type(of: field) == "id", !["contains", "doesNotContain", "matches"].contains(op) { return .null }
        switch type(of: field) {
        case "number": return op == "isbetween" ? .object(["num1": .number(0), "num2": .number(0)]) : .number(0)
        case "boolean": return .bool(false)
        case "date": return .string(BudgetDate.day(Date()))
        default: return .string("")
        }
    }

    /// With a new field or operator, a condition keeps its value only when it still fits.
    func changing(field newField: String? = nil, op newOp: String? = nil) -> RuleItem {
        let field = newField ?? self.field
        var op = newOp ?? self.op
        if !isAction, !Self.ops(for: field).contains(op) { op = Self.ops(for: field)[0] }
        var item = self
        item.raw["field"] = .string(field)
        item.raw["op"] = .string(op)
        item.raw["type"] = .string(Self.type(of: field))
        let multi = ["oneOf", "notOneOf"], empty = ["onBudget", "offBudget"]
        if field != self.field || multi.contains(op) != multi.contains(self.op)
            || (op == "isbetween") != (self.op == "isbetween") || empty.contains(op) || empty.contains(self.op) {
            item.raw["value"] = Self.defaultValue(field: field, op: op)
        }
        // Inflow and outflow apply to amount conditions only.
        if !isAction, field != "amount" { item.raw["options"] = nil }
        return item
    }

    /// An action with another operation: setting a field, adding to notes, or deleting the transaction.
    /// Keeps the action's split, and its identity, so an editor showing it keeps editing it.
    func withActionOp(_ op: String) -> RuleItem {
        let split = splitIndex
        var item = switch op {
        case "set":
            RuleItem.action(field: RuleItem.actionFields(split: split).contains(field) ? field : "category", split: split)
        case "delete-transaction":
            RuleItem(raw: ["op": .string(op), "options": .object(["splitIndex": .number(split)])])
        default:
            RuleItem(raw: ["op": .string(op), "field": .string("notes"), "type": .string("string"),
                           "value": .string(""), "options": .object(["splitIndex": .number(split)])])
        }
        item.id = id
        return item
    }

    /// A split's share with another allocation method. A fixed amount or percent starts at zero.
    func withSplitMethod(_ method: String) -> RuleItem {
        guard method != splitMethod else { return self }
        var item = RuleItem.splitAmount(split: splitIndex, method: method)
        item.id = id
        return item
    }

    var isAction: Bool { ["set", "prepend-notes", "append-notes", "delete-transaction", "link-schedule", "set-split-amount"].contains(op) }

    var isEditableCondition: Bool {
        guard Self.conditionFields.contains(field), Self.ops(for: field).contains(op) else { return false }
        // Only amount's inflow and outflow options are edited here.
        if options.keys.contains(where: { !["inflow", "outflow"].contains($0) }) { return false }
        if field == "date", case .string = value { return true }
        return field != "date"
    }

    /// A named condition, such as Actual's "Selected transactions". Actual shows its name and does not apply it in reports.
    var customName: String? { if case .string(let name) = raw["customName"] { name } else { nil } }

    /// Whether this app's editor offers every part of a report filter.
    var isEditableFilter: Bool {
        guard customName == nil, Self.filterFields.contains(field), Self.ops(for: field).contains(op) else { return false }
        // Month and year dates, and other options, are edited in Actual.
        if options.keys.contains(where: { !["inflow", "outflow"].contains($0) }) { return false }
        if field == "date" {
            if case .string(let day) = value { return day.count == 10 }
            return false
        }
        return true
    }

    var isEditableAction: Bool {
        // Templated values and formulas are edited in Actual.
        if op == "set-split-amount" {
            return splitIndex > 0 && Self.splitMethods.contains(splitMethod)
                && !options.keys.contains { !["splitIndex", "method"].contains($0) }
        }
        if options.keys.contains(where: { $0 != "splitIndex" }) { return false }
        switch op {
        case "set": return Self.actionFields(split: splitIndex, current: field).contains(field)
        case "prepend-notes", "append-notes", "delete-transaction": return true
        default: return false
        }
    }
}

/// Plain-language rules, as Actual's rules list describes them.
struct RuleDescriber {
    var payees: [String: String]
    var accounts: [String: String]
    var categories: [String: String]
    var currency: String
    var groups: [String: String] = [:]

    static let opNames: [String: String] = [
        "is": "is", "isNot": "is not", "contains": "contains", "doesNotContain": "does not contain",
        "matches": "matches", "oneOf": "is one of", "notOneOf": "is not one of", "isapprox": "is approximately",
        "isbetween": "is between", "gt": "is greater than", "gte": "is greater than or equal to",
        "lt": "is less than", "lte": "is less than or equal to", "onBudget": "is on budget", "offBudget": "is off budget",
        "hasTags": "has tags", "hasAnyTag": "has any tag",
    ]

    static func fieldName(_ field: String, options: [String: JSONValue] = [:]) -> String {
        if field == "amount", options["inflow"] == .bool(true) { return "amount (inflow)" }
        if field == "amount", options["outflow"] == .bool(true) { return "amount (outflow)" }
        return switch field {
        case "imported_payee": "imported payee"
        case "payee_name": "payee name"
        case "category_group": "category group"
        default: field.replacingOccurrences(of: "_", with: " ")
        }
    }

    func value(_ value: JSONValue, field: String) -> String {
        switch value {
        case .null: return "nothing"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number) where field == "amount": return Money.formatted(number, currency: currency)
        case .number(let number): return String(number)
        case .double(let number): return String(number)
        case .string(let text):
            let names = field == "payee" ? payees : field == "account" ? accounts : field == "category" ? categories
                : field == "category_group" ? groups : [:]
            if let name = names[text] { return name }
            return text.isEmpty ? "nothing" : "“\(text)”"
        case .array(let items): return items.map { self.value($0, field: field) }.joined(separator: ", ")
        case .object(let fields):
            if case .number(let low) = fields["num1"], case .number(let high) = fields["num2"] {
                return "\(Money.formatted(low, currency: currency)) and \(Money.formatted(high, currency: currency))"
            }
            return "a repeating date"
        }
    }

    func condition(_ item: RuleItem) -> String {
        let op = Self.opNames[item.op] ?? item.op
        let field = Self.fieldName(item.field, options: item.options)
        return ["onBudget", "offBudget"].contains(item.op) ? "\(field) \(op)" : "\(field) \(op) \(value(item.value, field: item.field))"
    }

    func action(_ item: RuleItem) -> String {
        switch item.op {
        case "set": "set \(Self.fieldName(item.field)) to \(value(item.value, field: item.field))"
        case "prepend-notes": "prepend \(value(item.value, field: "notes")) to notes"
        case "append-notes": "append \(value(item.value, field: "notes")) to notes"
        case "delete-transaction": "delete the transaction"
        case "link-schedule": "link to a schedule"
        case "set-split-amount": "allocate \(splitAmount(item))"
        default: item.op
        }
    }

    /// A split's share, as Actual's editor names its allocation methods.
    func splitAmount(_ item: RuleItem) -> String {
        switch item.splitMethod {
        case "fixed-amount":
            if case .number(let amount) = item.value { return "a fixed amount of \(Money.formatted(amount, currency: currency))" }
            return "a fixed amount"
        case "fixed-percent":
            let percent = switch item.value {
            case .number(let value): String(value)
            case .double(let value): value.formatted()
            default: "0"
            }
            return "\(percent)% of the remainder"
        case "formula": return "an amount based on a formula"
        default: return "an equal portion of the remainder"
        }
    }

    func describe(_ rule: Rule) -> String {
        let joiner = rule.conditionsOp == "or" ? " or " : " and "
        let conditions = rule.conditions.map(condition).joined(separator: joiner)
        var parts = rule.actionIndices(split: 0).map { action(rule.actions[$0]) }
        if rule.splitCount > 0 {
            // As Actual's rules list shows split rules: each split's actions in turn.
            let splits = (1...rule.splitCount).map { split in
                "split \(split): " + rule.actionIndices(split: split).map { action(rule.actions[$0]) }.joined(separator: ", ")
            }
            parts.append("split into " + splits.joined(separator: "; "))
        }
        let actions = parts.joined(separator: ", ")
        return conditions.isEmpty ? "Always \(actions)" : "If \(conditions), then \(actions)"
    }
}
