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

/// A rule condition or action, kept as Actual's JSON so settings this app does not edit survive saving.
struct RuleItem: Decodable, Sendable, Equatable, Identifiable {
    var raw: [String: JSONValue]
    /// For lists only; not saved.
    let id = UUID()

    init(raw: [String: JSONValue]) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try [String: JSONValue](from: decoder) }
    static func == (a: RuleItem, b: RuleItem) -> Bool { a.raw == b.raw }

    var field: String { if case .string(let value) = raw["field"] { value } else { "" } }
    var op: String { if case .string(let value) = raw["op"] { value } else { "" } }
    var value: JSONValue { raw["value"] ?? .null }
    var options: [String: JSONValue] { if case .object(let value) = raw["options"] { value } else { [:] } }

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
    static let conditionFields = ["imported_payee", "payee", "account", "category", "date", "notes", "amount", "cleared"]
    static let actionFields = ["category", "payee", "payee_name", "notes", "cleared", "account", "date", "amount"]

    /// Actual's valid operators for a condition field (shared/rules.ts), less tags.
    static func ops(for field: String) -> [String] {
        switch field {
        case "payee", "category": ["is", "contains", "matches", "oneOf", "isNot", "doesNotContain", "notOneOf"]
        case "account": ["is", "contains", "matches", "oneOf", "isNot", "doesNotContain", "notOneOf", "onBudget", "offBudget"]
        case "imported_payee": ["is", "contains", "matches", "oneOf", "isNot", "doesNotContain", "notOneOf"]
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

    static func action(field: String) -> RuleItem {
        RuleItem(raw: ["field": .string(field), "op": .string("set"), "type": .string(type(of: field)),
                       "value": defaultValue(field: field, op: "set"), "options": .object(["splitIndex": .number(0)])])
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
    func withActionOp(_ op: String) -> RuleItem {
        switch op {
        case "set": return RuleItem.action(field: RuleItem.actionFields.contains(field) ? field : "category")
        case "delete-transaction":
            return RuleItem(raw: ["op": .string(op), "options": .object(["splitIndex": .number(0)])])
        default:
            return RuleItem(raw: ["op": .string(op), "field": .string("notes"), "type": .string("string"),
                                  "value": .string(""), "options": .object(["splitIndex": .number(0)])])
        }
    }

    var isAction: Bool { ["set", "prepend-notes", "append-notes", "delete-transaction", "link-schedule", "set-split-amount"].contains(op) }

    var isEditableCondition: Bool {
        guard Self.conditionFields.contains(field), Self.ops(for: field).contains(op) else { return false }
        // Only amount's inflow and outflow options are edited here.
        if options.keys.contains(where: { !["inflow", "outflow"].contains($0) }) { return false }
        if field == "date", case .string = value { return true }
        return field != "date"
    }

    var isEditableAction: Bool {
        // Split actions and templated values are edited in Actual.
        if case .number(let split) = options["splitIndex"], split != 0 { return false }
        if options.keys.contains(where: { $0 != "splitIndex" }) { return false }
        switch op {
        case "set": return Self.actionFields.contains(field)
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
            let names = field == "payee" ? payees : field == "account" ? accounts : field == "category" ? categories : [:]
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
        case "set-split-amount": "split the transaction"
        default: item.op
        }
    }

    func describe(_ rule: Rule) -> String {
        let joiner = rule.conditionsOp == "or" ? " or " : " and "
        let conditions = rule.conditions.map(condition).joined(separator: joiner)
        let actions = rule.actions.map(action).joined(separator: ", ")
        return conditions.isEmpty ? "Always \(actions)" : "If \(conditions), then \(actions)"
    }
}
