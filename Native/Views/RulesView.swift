import SwiftUI

/// Actual's rules page: every rule in plain language, to edit, apply, or delete.
struct RulesView: View {
    @Environment(AppModel.self) private var model
    @State private var rules: [Rule] = []
    @State private var loadError: String?
    @State private var search = ""
    @State private var editing: RuleEditRoute?

    private var describer: RuleDescriber { RuleDescriber(model: model) }
    private var shown: [Rule] {
        let describer = describer
        return rules.filter { search.isEmpty || describer.describe($0).localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        let describer = describer
        ThemedList {
            if let error = model.errorMessage ?? loadError { Section { ErrorNotice(message: error) } }
            ForEach(shown) { rule in
                Button { editing = RuleEditRoute(rule: rule) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let stage = rule.stage {
                            Text(stage == "pre" ? "Runs first" : "Runs last").font(.caption.weight(.semibold))
                                .foregroundStyle(ActualTheme.accent)
                        }
                        Text(describer.describe(rule)).font(.subheadline).foregroundStyle(Color.primary)
                            .multilineTextAlignment(.leading)
                        if rule.isSchedule {
                            Label("From a schedule", systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
                        } else if !rule.isEditable {
                            Label("Edit in Actual", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
            }
        }
        .overlay {
            if shown.isEmpty && loadError == nil {
                ContentUnavailableView(search.isEmpty ? "No rules" : "No matching rules", systemImage: "wand.and.rays",
                                       description: Text(search.isEmpty ? "Rules categorize, rename, and tidy transactions as they arrive." : ""))
            }
        }
        .navigationTitle("Rules")
        .searchable(text: $search, prompt: "Search rules")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add rule", systemImage: "plus") { editing = RuleEditRoute(rule: .new()) }.disabled(model.isBusy)
            }
        }
        .task(id: model.dataRevision) { await load() }
        .sheet(item: $editing) { route in RuleEditor(rule: route.rule) }
    }

    private func load() async {
        do { rules = try await model.rules(); loadError = nil }
        catch { loadError = error.localizedDescription }
    }
}

struct RuleEditRoute: Identifiable {
    let id = UUID()
    let rule: Rule
}

extension RuleDescriber {
    @MainActor init(model: AppModel) {
        self.init(
            payees: Dictionary((model.overview?.payees ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }),
            accounts: Dictionary((model.overview?.accounts ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }),
            categories: Dictionary((model.budget?.categories ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }),
            currency: model.currency)
    }
}

/// Creates or edits a rule, as Actual's rule editor does.
struct RuleEditor: View {
    @State var rule: Rule
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var matches: Int?
    @State private var confirmsApply = false
    @State private var confirmsDelete = false
    @State private var applied: String?

    private var editable: Bool { rule.isEditable }
    private var describer: RuleDescriber { RuleDescriber(model: model) }

    var body: some View {
        let describer = describer
        NavigationStack {
            ThemedForm {
                if !editable {
                    Section {
                        Label(rule.isSchedule ? "From a schedule" : "View only", systemImage: "lock")
                        Text(rule.isSchedule
                             ? "Edit this rule by editing its schedule."
                             : "This rule uses settings this app doesn’t edit yet, such as splits, templates, or tags. Edit it in the Actual web or desktop app.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Picker("Runs", selection: Binding(get: { rule.stage ?? "" }, set: { rule.stage = $0.isEmpty ? nil : $0 })) {
                        Text("First").tag("pre")
                        Text("Normally").tag("")
                        Text("Last").tag("post")
                    }.pickerStyle(.segmented)
                } header: { Text("Stage") } footer: {
                    Text("Rules run in stages: first, then normally, then last.")
                }.disabled(!editable)
                Section {
                    if rule.conditions.count > 1 {
                        Picker("Match", selection: $rule.conditionsOp) {
                            Text("All conditions").tag("and")
                            Text("Any condition").tag("or")
                        }
                    }
                    ForEach($rule.conditions) { $item in
                        NavigationLink { ConditionEditor(item: $item) } label: {
                            Text(describer.condition(item)).foregroundStyle(Color.primary)
                        }
                    }
                    .onDelete { rule.conditions.remove(atOffsets: $0) }
                    Button("Add Condition", systemImage: "plus") { rule.conditions.append(.condition(field: "payee")) }
                } header: { Text("If") } footer: {
                    if rule.conditions.isEmpty { Text("Without conditions, the rule applies to every transaction.") }
                }.disabled(!editable)
                Section("Then") {
                    ForEach($rule.actions) { $item in
                        NavigationLink { ActionEditor(item: $item) } label: {
                            Text(describer.action(item)).foregroundStyle(Color.primary)
                        }
                    }
                    .onDelete { rule.actions.remove(atOffsets: $0) }
                    Button("Add Action", systemImage: "plus") {
                        let used = Set(rule.actions.map(\.field))
                        rule.actions.append(.action(field: RuleItem.actionFields.first { !used.contains($0) } ?? "category"))
                    }
                }.disabled(!editable)
                Section {
                    if let matches {
                        Text(matches == 1 ? "Matches 1 transaction" : "Matches \(matches) transactions")
                    }
                    if !rule.id.isEmpty, editable, (matches ?? 0) > 0 {
                        Button("Apply to Matching Transactions", systemImage: "wand.and.stars") { confirmsApply = true }
                    }
                    if let applied { Text(applied).foregroundStyle(.secondary) }
                } footer: {
                    Text("Rules run on new and imported transactions. Applying runs the actions on transactions that match now.")
                }
                if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
                if !rule.id.isEmpty && !rule.isSchedule {
                    Section { Button("Delete Rule", role: .destructive) { confirmsDelete = true } }
                }
            }
            .disabled(model.isBusy)
            .deleteDisabled(!editable)
            .navigationTitle(rule.id.isEmpty ? "New Rule" : "Rule").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(editable ? "Cancel" : "Done") { dismiss() } }
                if editable {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task { if await model.manage("saveRule", rule.json) { dismiss() } }
                        }.bold()
                    }
                }
            }
            .task(id: rule.conditions.map(\.raw).description + rule.conditionsOp) {
                // Wait for typing to pause: each count queries every transaction.
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                matches = try? await model.ruleMatches(rule)
            }
            .confirmationDialog("Apply this rule to \(matches ?? 0) transactions?", isPresented: $confirmsApply,
                                titleVisibility: .visible) {
                Button("Apply") {
                    Task {
                        if await model.manage("applyRule", rule.json) {
                            applied = "Applied to matching transactions."
                        }
                    }
                }
            } message: { Text("This saved version’s actions change those transactions now.") }
            .confirmationDialog("Delete this rule?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Rule", role: .destructive) {
                    Task { if await model.manage("deleteRule", ["id": .string(rule.id)]) { dismiss() } }
                }
            }
        }
        .environment(\.ruleEditable, editable)
    }
}

private struct RuleEditableKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var ruleEditable: Bool {
        get { self[RuleEditableKey.self] }
        set { self[RuleEditableKey.self] = newValue }
    }
}

/// A condition's field, how it matches, and its value.
private struct ConditionEditor: View {
    @Binding var item: RuleItem
    @Environment(\.ruleEditable) private var editable

    private var direction: String {
        if item.options["inflow"] == .bool(true) { return "inflow" }
        if item.options["outflow"] == .bool(true) { return "outflow" }
        return ""
    }

    var body: some View {
        ThemedForm {
            Section {
                Picker("Field", selection: Binding(get: { item.field }, set: { item = item.changing(field: $0) })) {
                    ForEach(RuleItem.conditionFields, id: \.self) { Text(RuleDescriber.fieldName($0).capitalized).tag($0) }
                }
                if item.field == "amount" {
                    Picker("Direction", selection: Binding(get: { direction }, set: { value in
                        item.raw["options"] = value.isEmpty ? nil : .object([value: .bool(true)])
                    })) {
                        Text("Any").tag("")
                        Text("Inflow").tag("inflow")
                        Text("Outflow").tag("outflow")
                    }
                }
                Picker("Match", selection: Binding(get: { item.op }, set: { item = item.changing(op: $0) })) {
                    ForEach(RuleItem.ops(for: item.field), id: \.self) { Text(RuleDescriber.opNames[$0] ?? $0).tag($0) }
                }
            }
            if !["onBudget", "offBudget"].contains(item.op) {
                Section("Value") { RuleValueEditor(item: $item, signed: direction.isEmpty) }
            }
        }
        .disabled(!editable)
        .navigationTitle("Condition").navigationBarTitleDisplayMode(.inline)
    }
}

/// An action: set a field, add to notes, or delete the transaction.
private struct ActionEditor: View {
    @Binding var item: RuleItem
    @Environment(\.ruleEditable) private var editable

    var body: some View {
        ThemedForm {
            Section {
                Picker("Action", selection: Binding(get: { item.op }, set: { item = item.withActionOp($0) })) {
                    Text("Set a field").tag("set")
                    Text("Add to start of notes").tag("prepend-notes")
                    Text("Add to end of notes").tag("append-notes")
                    Text("Delete transaction").tag("delete-transaction")
                }
                if item.op == "set" {
                    Picker("Field", selection: Binding(get: { item.field }, set: { item = item.changing(field: $0) })) {
                        ForEach(RuleItem.actionFields, id: \.self) { Text(RuleDescriber.fieldName($0).capitalized).tag($0) }
                    }
                }
            }
            if item.op != "delete-transaction" {
                Section("Value") { RuleValueEditor(item: $item, signed: true) }
            }
        }
        .disabled(!editable)
        .navigationTitle("Action").navigationBarTitleDisplayMode(.inline)
    }
}

/// A condition's or action's value, edited by its field's type.
private struct RuleValueEditor: View {
    @Binding var item: RuleItem
    /// Amounts without a direction are signed: payments are negative.
    var signed: Bool
    @Environment(AppModel.self) private var model

    private var options: [(id: String, name: String)] {
        switch item.field {
        case "payee": (model.overview?.payees ?? []).map { ($0.id, $0.name) }
        case "account": (model.overview?.accounts ?? []).map { ($0.id, $0.name) }
        case "category": (model.budget?.categories ?? []).map { ($0.id, $0.name) }
        default: []
        }
    }

    var body: some View {
        let type = RuleItem.type(of: item.field)
        let textMatch = ["contains", "doesNotContain", "matches"].contains(item.op)
        if ["oneOf", "notOneOf"].contains(item.op) {
            if type == "id" {
                NavigationLink {
                    IDMultiPicker(options: options, selection: Binding(
                        get: { if case .array(let values) = item.value { values.compactMap { if case .string(let id) = $0 { id } else { nil } } } else { [] } },
                        set: { item.raw["value"] = .array($0.map { .string($0) }) }))
                } label: {
                    LabeledContent("Values", value: RuleDescriber(model: model).value(item.value, field: item.field))
                }
            } else {
                TextField("One value per line", text: Binding(
                    get: { if case .array(let values) = item.value { values.compactMap { if case .string(let text) = $0 { text } else { nil } }.joined(separator: "\n") } else { "" } },
                    set: { item.raw["value"] = .array($0.split(separator: "\n").map { .string(String($0)) }) }),
                          axis: .vertical).lineLimit(3...8)
            }
        } else if type == "id" && !textMatch {
            NavigationLink {
                IDPicker(title: RuleDescriber.fieldName(item.field).capitalized, options: options, selection: stringValue)
            } label: {
                LabeledContent(RuleDescriber.fieldName(item.field).capitalized,
                               value: options.first { $0.id == stringValue.wrappedValue }?.name ?? "Choose")
            }
        } else if type == "number" {
            if item.op == "isbetween" {
                AmountValueField(label: "From", value: rangeValue("num1"), signed: signed)
                AmountValueField(label: "To", value: rangeValue("num2"), signed: signed)
            } else {
                AmountValueField(label: "Amount", value: numberValue, signed: signed)
            }
        } else if type == "date" {
            DatePicker("Date", selection: Binding(
                get: { BudgetDate.date(stringValue.wrappedValue) ?? Date() },
                set: { stringValue.wrappedValue = BudgetDate.day($0) }), displayedComponents: .date)
        } else if type == "boolean" {
            Toggle(RuleDescriber.fieldName(item.field).capitalized, isOn: Binding(
                get: { item.value == .bool(true) }, set: { item.raw["value"] = .bool($0) }))
        } else {
            TextField(textMatch && item.op == "matches" ? "Regular expression" : "Text", text: stringValue, axis: .vertical)
        }
    }

    private var stringValue: Binding<String> {
        Binding(get: { if case .string(let text) = item.value { text } else { "" } },
                set: { item.raw["value"] = .string($0) })
    }
    private var numberValue: Binding<Int> {
        Binding(get: { if case .number(let value) = item.value { value } else { 0 } },
                set: { item.raw["value"] = .number($0) })
    }
    private func rangeValue(_ key: String) -> Binding<Int> {
        Binding(get: {
            if case .object(let range) = item.value, case .number(let value) = range[key] { value } else { 0 }
        }, set: { value in
            var range: [String: JSONValue] = [:]
            if case .object(let current) = item.value { range = current }
            range[key] = .number(value)
            item.raw["value"] = .object(range)
        })
    }
}

/// An amount in minor units, entered with the calculator keypad.
private struct AmountValueField: View {
    let label: String
    @Binding var value: Int
    var signed: Bool
    @State private var text = ""
    @State private var isOutflow = true
    @State private var loaded = false

    var body: some View {
        Group {
            if signed {
                Picker("Type", selection: $isOutflow) {
                    Text("Payment").tag(true)
                    Text("Deposit").tag(false)
                }.pickerStyle(.segmented)
            }
            AmountField(label: label, text: $text)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            isOutflow = value <= 0
            text = Money.editable(abs(value))
        }
        .onChange(of: text) { update() }
        .onChange(of: isOutflow) { update() }
    }

    private func update() {
        guard let cents = Money.parse(text) else { return }
        value = signed && isOutflow ? -abs(cents) : abs(cents)
    }
}

private struct IDPicker: View {
    let title: String
    let options: [(id: String, name: String)]
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        List(options.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }, id: \.id) { option in
            Button { selection = option.id; dismiss() } label: {
                CheckRow(title: option.name, selected: selection == option.id)
            }.themedRows()
        }
        .themedPage()
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
    }
}

private struct IDMultiPicker: View {
    let options: [(id: String, name: String)]
    @Binding var selection: [String]
    @State private var search = ""

    var body: some View {
        List(options.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }, id: \.id) { option in
            Button {
                if let index = selection.firstIndex(of: option.id) { selection.remove(at: index) }
                else { selection.append(option.id) }
            } label: {
                CheckRow(title: option.name, selected: selection.contains(option.id))
            }.themedRows()
        }
        .themedPage()
        .navigationTitle("Values").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
    }
}
