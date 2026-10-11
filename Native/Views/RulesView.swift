import SwiftUI

/// Actual's rules page: every rule in plain language, in the order they run, to edit, apply, or delete.
/// With a payee, as Actual's payees page opens it: that payee's rules.
struct RulesView: View {
    var payeeID: String? = nil
    var payeeName: String? = nil
    @Environment(AppModel.self) private var model
    @State private var rules: [Rule] = []
    @State private var loadError: String?
    @State private var search = ""
    @State private var editing: RuleEditRoute?
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<String> = []
    @State private var deleting: [String] = []

    private var describer: RuleDescriber { RuleDescriber(model: model) }
    private var shown: [Rule] {
        let describer = describer
        return rules.filter { search.isEmpty || describer.describe($0).localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        let describer = describer
        List(selection: $selection) {
            Group {
                if let error = model.errorMessage ?? loadError { Section { ErrorNotice(message: error) } }
                Section {
                    ForEach(shown) { rule in
                        row(rule, describer: describer)
                            .tag(rule.id)
                            // Schedules keep their rules, as in Actual.
                            .selectionDisabled(rule.isSchedule)
                            .swipeActions {
                                if !rule.isSchedule {
                                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = [rule.id] }
                                }
                            }
                    }
                } footer: {
                    if !shown.isEmpty { Text("Rules run in the order shown: those that run first, then the rest, then those that run last.") }
                }
            }.themedRows()
        }
        .themedPage()
        .environment(\.editMode, $editMode)
        .overlay {
            if shown.isEmpty && loadError == nil {
                ContentUnavailableView(search.isEmpty ? "No rules" : "No matching rules", systemImage: "wand.and.rays",
                                       description: Text(search.isEmpty ? "Rules categorize, rename, and tidy transactions as they arrive." : ""))
            }
        }
        .navigationTitle("Rules")
        .navigationSubtitle(payeeName ?? "")
        .searchable(text: $search, prompt: "Search rules")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode.isEditing ? "Done" : "Select") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    selection = []
                }.disabled(rules.allSatisfy(\.isSchedule) && !editMode.isEditing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add rule", systemImage: "plus") { editing = RuleEditRoute(rule: .new(payeeID: payeeID)) }
                    .disabled(model.isBusy || editMode.isEditing)
            }
            if editMode.isEditing {
                ToolbarItem(placement: .bottomBar) {
                    Button(selection.isEmpty ? "Delete" : "Delete \(selection.count)", role: .destructive) {
                        deleting = Array(selection)
                    }.disabled(selection.isEmpty || model.isBusy)
                }
            }
        }
        .task(id: model.dataRevision) { await load() }
        .sheet(item: $editing) { route in RuleEditor(rule: route.rule) }
        .confirmationDialog(deleting.count == 1 ? "Delete this rule?" : "Delete \(deleting.count) rules?",
                            isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }),
                            titleVisibility: .visible) {
            Button(deleting.count == 1 ? "Delete Rule" : "Delete Rules", role: .destructive) {
                let ids = deleting
                Task {
                    if await model.manage("deleteRules", ["ids": .array(ids.map { .string($0) })]) {
                        selection = []
                        editMode = .inactive
                    }
                }
            }
        }
    }

    @ViewBuilder private func row(_ rule: Rule, describer: RuleDescriber) -> some View {
        let label = VStack(alignment: .leading, spacing: 6) {
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
        // While selecting, a tap selects the rule instead of opening it.
        if editMode.isEditing { label } else { Button { editing = RuleEditRoute(rule: rule) } label: { label } }
    }

    private func load() async {
        do { rules = try await model.rules(payeeID: payeeID); loadError = nil }
        catch { loadError = error.localizedDescription }
    }
}

extension Rule {
    /// As Actual's "Create new rule": if the payee is the one given, set a category.
    static func new(payeeID: String?) -> Rule {
        var rule = Rule.new()
        if let payeeID { rule.conditions[0].raw["value"] = .string(payeeID) }
        return rule
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
            currency: model.currency,
            groups: Dictionary((model.budget?.groups ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
    }
}

/// Creates or edits a rule, as Actual's rule editor does.
struct RuleEditor: View {
    @State var rule: Rule
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var matches: [RuleMatch]?
    @State private var confirmsDelete = false

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
                             : "This rule uses settings this app doesn’t edit yet, such as templates or formulas. Edit it in the Actual web or desktop app.")
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
                    if editable {
                        Button("Add Condition", systemImage: "plus") { rule.conditions.append(.condition(field: "payee")) }
                    }
                } header: { Text("If") } footer: {
                    if rule.conditions.isEmpty { Text("Without conditions, the rule applies to every transaction.") }
                }.disabled(!editable)
                actions(split: 0, describer: describer)
                if rule.splitCount > 0 {
                    ForEach(1...rule.splitCount, id: \.self) { split in actions(split: split, describer: describer) }
                }
                if editable && !rule.isSchedule {
                    Section {
                        Button(rule.splitCount > 0 ? "Add Another Split" : "Split into Multiple Transactions",
                               systemImage: "arrow.triangle.branch") { rule.addSplit() }
                    } footer: {
                        Text(rule.splitCount > 0
                             ? "Fixed amounts are taken first, then percentages of what remains; equal portions share the rest."
                             : "A split rule divides each matching transaction into parts, each with its own category, payee, or notes.")
                    }
                }
                Section {
                    NavigationLink {
                        RuleMatchesView(rule: rule, matches: matches ?? [], editable: editable) { matches = $0 }
                    } label: {
                        LabeledContent("Matching Transactions", value: matches.map { "\($0.count)" } ?? "…")
                    }.disabled(matches == nil)
                } footer: {
                    Text("Rules run on new and imported transactions. You can also apply this rule’s actions to transactions that match now.")
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
            .task(id: rule.conditions.map(\.raw).description + rule.conditionsOp + "\(rule.splitCount > 0)") {
                // Wait for typing to pause: each count queries every transaction.
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                matches = try? await model.ruleMatches(rule)
            }
            .confirmationDialog("Delete this rule?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Rule", role: .destructive) {
                    Task { if await model.manage("deleteRule", ["id": .string(rule.id)]) { dismiss() } }
                }
            }
        }
        .environment(\.ruleEditable, editable)
    }

    /// The actions before splitting, or one split's share and actions, as Actual's editor groups them.
    @ViewBuilder private func actions(split: Int, describer: RuleDescriber) -> some View {
        let indices = rule.actionIndices(split: split)
        Section {
            ForEach(indices.map { rule.actions[$0].id }, id: \.self) { id in
                if let index = rule.actions.firstIndex(where: { $0.id == id }) {
                    let item = rule.actions[index]
                    NavigationLink {
                        if item.op == "set-split-amount" { SplitAmountEditor(item: $rule.actions[index]) }
                        else { ActionEditor(item: $rule.actions[index]) }
                    } label: {
                        Text(describer.action(item)).foregroundStyle(Color.primary)
                    }
                    // A split's share is removed with the split.
                    .deleteDisabled(item.op == "set-split-amount")
                }
            }
            .onDelete { offsets in
                let ids = Set(offsets.map { rule.actions[indices[$0]].id })
                rule.actions.removeAll { ids.contains($0.id) }
            }
            if editable { Button("Add Action", systemImage: "plus") { rule.addAction(split: split) } }
            if editable && split > 0 {
                Button("Remove Split", systemImage: "minus.circle", role: .destructive) { rule.removeSplit(split) }
            }
        } header: {
            Text(split == 0 ? (rule.splitCount > 0 ? "Then, before splitting" : "Then") : "Split \(split)")
        }.disabled(!editable)
    }
}

/// The transactions a rule matches now, to choose which its actions apply to, as Actual's editor lists them.
private struct RuleMatchesView: View {
    let rule: Rule
    let matches: [RuleMatch]
    let editable: Bool
    var reloaded: ([RuleMatch]) -> Void
    @Environment(AppModel.self) private var model
    @State private var selection: Set<String> = []
    @State private var confirmsApply = false
    @State private var applied: String?

    var body: some View {
        let names = RuleDescriber(model: model)
        List(selection: $selection) {
            Group {
                if let applied { Section { Label(applied, systemImage: "checkmark.circle").foregroundStyle(.secondary) } }
                if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
                Section {
                    ForEach(matches) { match in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.payeeId.flatMap { names.payees[$0] } ?? "No payee")
                                Text([BudgetDate.display(match.date), names.accounts[match.accountId],
                                      match.categoryId.flatMap { names.categories[$0] }]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                if !match.notes.isEmpty {
                                    Text(match.notes).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(Money.formatted(match.amount, currency: model.currency)).monospacedDigit()
                                .foregroundStyle(match.amount > 0 ? ActualTheme.positive : Color.primary)
                        }.tag(match.id)
                    }
                } footer: {
                    if editable && !matches.isEmpty {
                        Text("Choose transactions to apply this rule’s actions to, as they are in the editor now.")
                    }
                }
            }.themedRows()
        }
        .listStyle(.insetGrouped)
        .themedPage()
        .environment(\.editMode, .constant(editable ? .active : .inactive))
        .overlay {
            if matches.isEmpty { ContentUnavailableView("No matching transactions", systemImage: "line.3.horizontal.decrease") }
        }
        .navigationTitle("Matching Transactions").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if editable && !matches.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selection.count == matches.count ? "Select None" : "Select All") {
                        selection = selection.count == matches.count ? [] : Set(matches.map(\.id))
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(selection.isEmpty ? "Apply Actions" : "Apply to \(selection.count)", systemImage: "wand.and.stars") {
                        confirmsApply = true
                    }.disabled(selection.isEmpty || model.isBusy)
                }
            }
        }
        .confirmationDialog(selection.count == 1 ? "Apply this rule to 1 transaction?" : "Apply this rule to \(selection.count) transactions?",
                            isPresented: $confirmsApply, titleVisibility: .visible) {
            Button("Apply") { Task { await apply() } }
        } message: { Text("The rule’s actions change these transactions now.") }
    }

    private func apply() async {
        var arguments = rule.json
        arguments["ids"] = .array(selection.map { .string($0) })
        let count = selection.count
        guard await model.manage("applyRule", arguments) else { return }
        applied = count == 1 ? "Applied to 1 transaction." : "Applied to \(count) transactions."
        selection = []
        // Applied actions can change which transactions match.
        if let fresh = try? await model.ruleMatches(rule) { reloaded(fresh) }
    }
}

private struct RuleEditableKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var ruleEditable: Bool {
        get { self[RuleEditableKey.self] }
        set { self[RuleEditableKey.self] = newValue }
    }
}

/// A condition's field, how it matches, and its value. Rules and report filters share it.
struct ConditionEditor: View {
    @Binding var item: RuleItem
    /// The fields offered: a rule's, or a report filter's.
    var fields = RuleItem.conditionFields
    var title = "Condition"
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
                    ForEach(fields, id: \.self) { Text(RuleDescriber.fieldName($0).capitalized).tag($0) }
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
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}

/// An action: set a field, add to notes, or delete the transaction. In a split, it applies to that part.
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
                        ForEach(RuleItem.actionFields(split: item.splitIndex, current: item.field), id: \.self) {
                            Text(RuleDescriber.fieldName($0).capitalized).tag($0)
                        }
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

/// A split's share of the transaction's amount, by Actual's allocation methods.
private struct SplitAmountEditor: View {
    @Binding var item: RuleItem
    @Environment(\.ruleEditable) private var editable
    @State private var percent = ""

    var body: some View {
        ThemedForm {
            Section {
                Picker("Allocate", selection: Binding(get: { item.splitMethod }, set: { item = item.withSplitMethod($0) })) {
                    Text("A fixed amount").tag("fixed-amount")
                    Text("A percent of the remainder").tag("fixed-percent")
                    Text("An equal portion of the remainder").tag("remainder")
                }.pickerStyle(.inline).labelsHidden()
            } header: { Text("Allocate") } footer: {
                Text("Fixed amounts are taken first, then percentages of what remains. Equal portions share the rest, and the last takes any rounding.")
            }
            if item.splitMethod == "fixed-amount" {
                Section("Amount") {
                    AmountValueField(label: "Amount", value: Binding(
                        get: { if case .number(let value) = item.value { value } else { 0 } },
                        set: { item.raw["value"] = .number($0) }), signed: true)
                }
            } else if item.splitMethod == "fixed-percent" {
                Section("Percent") {
                    HStack {
                        TextField("Percent", text: $percent).keyboardType(.decimalPad)
                        Text("%").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .disabled(!editable)
        .navigationTitle("Split Amount").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            percent = switch item.value {
            case .number(let value): String(value)
            case .double(let value): value.formatted(.number.grouping(.never))
            default: ""
            }
        }
        .onChange(of: percent) {
            guard item.splitMethod == "fixed-percent",
                  let value = Double(percent.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: "."))
            else { return }
            item.raw["value"] = value == value.rounded() ? .number(Int(value)) : .double(value)
        }
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
        case "category_group": (model.budget?.groups ?? []).map { ($0.id, $0.name) }
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
