import SwiftUI

/// Opens a category's targets from its budget editor.
struct TargetsRoute: Hashable {}

/// A category's targets, like Actual's budget automations editor.
/// Source edits the same targets in Actual's notes syntax, such as `#template 50`.
struct TargetsEditor: View {
    enum Mode: Hashable { case form, source }

    let category: BudgetCategory
    let month: String
    @Binding var path: NavigationPath
    @Environment(AppModel.self) private var model
    @State private var loaded: CategoryTargets?
    @State private var loadError: String?
    @State private var original: [TargetTemplate] = []
    @State private var templates: [TargetTemplate] = []
    @State private var preview: TargetPreview?
    /// The targets `preview` describes. Saving waits until it matches the edits.
    @State private var previewed: [TargetTemplate]?
    @State private var previewError: String?
    @State private var confirmDiscard = false
    @State private var mode = Mode.form
    @State private var sourceText = ""
    /// The source as it opened, and the targets it stands for until edited.
    @State private var sourceStart = ""
    @State private var sourceBase: [TargetTemplate] = []
    /// What Actual read from `parsedText`.
    @State private var parsed: ParsedTargets?
    @State private var parsedText: String?
    @State private var switching = false
    @State private var showSourceIssues = false

    private var hasChanges: Bool {
        templates.map(\.fields) != original.map(\.fields) || (mode == .source && sourceText != sourceStart)
    }
    /// Saving targets imported from notes moves them to the editor, as in Actual.
    private var migrates: Bool { loaded?.source == .notes && !templates.isEmpty }
    private var currentPreview: TargetPreview? { previewed == templates ? preview : nil }
    /// Lines Actual cannot read in the source, once it has read the latest text.
    private var sourceIssues: [ParsedTargets.Issue]? { parsedText == sourceText ? parsed?.errors : nil }
    private var canSave: Bool {
        guard let loaded, hasChanges || migrates, previewError == nil, let currentPreview else { return false }
        switch mode {
        case .form: guard loaded.unsupported.isEmpty else { return false }
        case .source: guard sourceIssues?.isEmpty == true else { return false }
        }
        return currentPreview.canSave && !model.isBusy
    }

    var body: some View {
        ThemedForm {
            if let loadError {
                Section { ErrorNotice(message: loadError) { Task { await load() } } }
            } else if let loaded {
                content(loaded)
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("Targets")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hasChanges)
        .toolbar {
            if hasChanges {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { confirmDiscard = true }.disabled(model.isBusy)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }.bold().disabled(!canSave)
            }
        }
        .confirmationDialog("Discard your changes to these targets?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { path.removeLast() }
        }
        .alert("Fix the source first", isPresented: $showSourceIssues) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The form can show the targets once Actual can read every line.")
        }
        .navigationDestination(for: UUID.self) { id in
            if let loaded {
                TargetDetail(
                    template: binding(id), all: templates, targets: loaded, currency: model.currency,
                    contribution: contribution(id), problem: problem(id),
                    delete: { path.removeLast(); templates.removeAll { $0.id == id } },
                    addCap: { add(.limit) })
            }
        }
        .task { if loaded == nil { await load() } }
        .task(id: templates) { await refreshPreview() }
        .task(id: mode == .source ? sourceText : nil) { await parseSource() }
    }

    @ViewBuilder private func content(_ loaded: CategoryTargets) -> some View {
        Section {
            Picker("Editor", selection: Binding(get: { mode }, set: { new in Task { await switchMode(to: new) } })) {
                Text("Form").tag(Mode.form)
                Text("Source").tag(Mode.source)
            }
            .pickerStyle(.segmented)
            .disabled(switching)
        }
        Section {
            LabeledContent("Projected for \(TargetTemplate.monthLabel(month))") {
                if mode == .source, sourceIssues?.isEmpty == false { Text("—").foregroundStyle(.secondary) }
                else if let currentPreview, mode == .form || sourceIssues != nil {
                    MoneyText(value: currentPreview.budgeted, currency: model.currency)
                } else { ProgressView() }
            }
            if let previewError { Text(previewError).foregroundStyle(ActualTheme.negative) }
        } footer: {
            if loaded.source == .notes, !loaded.noteLines.isEmpty {
                Text("Imported from the category’s notes. Review and save to manage these targets here; Actual then ignores the #template lines in its notes.")
            }
        }
        if mode == .form, loaded.source == .notes, !loaded.noteLines.isEmpty {
            Section {
                DisclosureGroup("Notes lines") {
                    ForEach(loaded.noteLines, id: \.self) { Text($0).font(.caption.monospaced()) }
                }
            }
        }
        if let conflicts = currentPreview?.conflicts, !conflicts.isEmpty {
            Section {
                ForEach(conflicts, id: \.self) { conflict in
                    Label(conflict, systemImage: "exclamationmark.circle").foregroundStyle(ActualTheme.negative)
                }
            }
        }
        switch mode {
        case .form: form(loaded)
        case .source: source(loaded)
        }
        if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
    }

    @ViewBuilder private func form(_ loaded: CategoryTargets) -> some View {
        Section {
            ForEach(templates.filter { !$0.isOption }) { row($0, loaded) }
                .onDelete { offsets in
                    let automations = templates.filter { !$0.isOption }
                    let ids = Set(offsets.map { automations[$0].id })
                    templates.removeAll { ids.contains($0.id) }
                }
            // Like Actual's editor: start with a fixed amount, then choose its type.
            Button("Add Automation", systemImage: "plus") { add(.fixed) }
        } header: {
            Text("Automations")
        } footer: {
            Text("Automations budget this category when you apply targets. Lower priorities are budgeted first.")
        }
        Section("Options") {
            ForEach(templates.filter(\.isOption)) { row($0, loaded) }
            if !templates.contains(where: { $0.kind == .limit }) {
                Button("Add Balance Cap", systemImage: "plus") { add(.limit) }
            }
            if !templates.contains(where: { $0.kind == .goal }) {
                Button("Add Long-Term Goal", systemImage: "plus") { add(.goal) }
            }
        }
    }

    /// Actual's notes syntax, read as you type. Saving stores the targets as the form does.
    @ViewBuilder private func source(_ loaded: CategoryTargets) -> some View {
        Section {
            TextEditor(text: $sourceText)
                .font(.callout.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(minHeight: 160)
        } header: {
            Text("Source")
        } footer: {
            Text("One target per line, as in Actual’s notes, such as `#template 50` or `#goal 500`. Text directly above a line becomes its note. [Syntax reference](https://actualbudget.org/docs/experimental/goal-templates)")
        }
        if let issues = sourceIssues, !issues.isEmpty {
            Section {
                ForEach(issues, id: \.self) { issue in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            if issue.line > 0 { Text("Line \(issue.line)").font(.subheadline.weight(.semibold)) }
                            if !issue.text.isEmpty { Text(issue.text).font(.caption.monospaced()) }
                            Text(issue.message).font(.caption)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                    }
                    .foregroundStyle(ActualTheme.negative)
                }
            }
        } else if sourceIssues != nil, !templates.isEmpty {
            Section("Targets") {
                ForEach(templates) { summary($0, loaded) }
            }
        }
    }

    private func row(_ template: TargetTemplate, _ loaded: CategoryTargets) -> some View {
        NavigationLink(value: template.id) { summary(template, loaded) }
    }

    private func summary(_ template: TargetTemplate, _ loaded: CategoryTargets) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label(template.kind?.title ?? "Target", systemImage: template.kind?.systemImage ?? "target")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if let amount = contribution(template.id) {
                    Text(amount > 0 ? "+" + Money.formatted(amount, currency: model.currency) : "—")
                        .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text(template.summary(currency: model.currency, income: loaded.incomeCategories))
                .font(.subheadline).foregroundStyle(.secondary)
            if let problem = problem(template.id) {
                Label(problem, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(ActualTheme.negative)
            }
        }
    }

    /// The template's share of this month's projection. Caps and goals contribute none.
    private func contribution(_ id: UUID) -> Int? {
        guard let preview = currentPreview, let index = templates.firstIndex(where: { $0.id == id }),
              index < preview.perTemplate.count,
              !templates[index].isOption else { return nil }
        return preview.perTemplate[index]
    }

    private func problem(_ id: UUID) -> String? {
        guard let preview = currentPreview, let index = templates.firstIndex(where: { $0.id == id }),
              index < preview.problems.count else { return nil }
        return preview.problems[index]
    }

    /// Stays valid after the template is deleted while its editor closes.
    private func binding(_ id: UUID) -> Binding<TargetTemplate> {
        let fallback = templates.first { $0.id == id } ?? TargetTemplate(kind: .fixed)
        return Binding(
            get: { templates.first { $0.id == id } ?? fallback },
            set: { value in
                if let index = templates.firstIndex(where: { $0.id == id }) { templates[index] = value }
            })
    }

    private func add(_ kind: TargetTemplate.Kind) {
        let template = TargetTemplate(kind: kind)
        templates.append(template)
        path.append(template.id)
    }

    private func load() async {
        loadError = nil
        do {
            let targets = try await model.categoryTargets(categoryID: category.id, month: month)
            original = targets.templates
            templates = targets.templates
            preview = targets.preview
            previewed = targets.templates
            loaded = targets
            // Lines Actual cannot read can be fixed only in the source.
            if !targets.unsupported.isEmpty { openSource(targets.sourceText) }
        } catch { loadError = error.localizedDescription }
    }

    private func switchMode(to new: Mode) async {
        guard new != mode, !switching, let loaded else { return }
        switch new {
        case .source:
            // Unchanged targets show as stored, keeping notes lines as written.
            if templates.map(\.fields) == original.map(\.fields) {
                openSource(loaded.sourceText)
                return
            }
            switching = true
            defer { switching = false }
            do { openSource(try await model.targetSource(templates: templates)) }
            catch { previewError = error.localizedDescription }
        case .form:
            guard sourceIssues?.isEmpty == true else { showSourceIssues = true; return }
            mode = .form
        }
    }

    private func openSource(_ text: String) {
        sourceText = text
        sourceStart = text
        sourceBase = templates
        parsed = nil
        parsedText = nil
        mode = .source
    }

    private func parseSource() async {
        guard mode == .source, parsedText != sourceText else { return }
        let text = sourceText
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            let result = try await model.parseTargets(categoryID: category.id, month: month, text: text)
            guard !Task.isCancelled else { return }
            if result.errors.isEmpty {
                if text == sourceStart {
                    // The untouched source stands for the targets it opened with, whose preview may already be current.
                    if templates.map(\.fields) != sourceBase.map(\.fields) { templates = sourceBase }
                } else if result.templates.map(\.fields) != templates.map(\.fields) || result.preview != currentPreview {
                    preview = result.preview
                    previewed = result.templates
                    templates = result.templates
                }
            }
            parsed = result
            parsedText = text
            previewError = nil
        } catch {
            guard !Task.isCancelled else { return }
            previewError = error.localizedDescription
        }
    }

    private func refreshPreview() async {
        guard loaded?.unsupported.isEmpty == true || mode == .source, previewed != templates else { return }
        let snapshot = templates
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        do {
            let result = try await model.previewTargets(categoryID: category.id, month: month, templates: snapshot)
            guard !Task.isCancelled else { return }
            preview = result
            previewed = snapshot
            previewError = nil
        } catch {
            guard !Task.isCancelled else { return }
            previewError = error.localizedDescription
        }
    }

    private func save() async {
        if await model.saveTargets(categoryID: category.id, templates: templates) {
            original = templates
            sourceStart = sourceText
            path.removeLast()
        }
    }
}

/// One target's settings, like the web editor's automation pane.
private struct TargetDetail: View {
    @Binding var template: TargetTemplate
    let all: [TargetTemplate]
    let targets: CategoryTargets
    let currency: String
    let contribution: Int?
    let problem: String?
    let delete: () -> Void
    let addCap: () -> Void

    private var kind: TargetTemplate.Kind { template.kind ?? .fixed }

    var body: some View {
        ThemedForm {
            Section {
                if TargetTemplate.Kind.automations.contains(kind) {
                    Picker("Type", selection: Binding(get: { kind }, set: { template.change(to: $0) })) {
                        ForEach(TargetTemplate.Kind.automations) { option in
                            Label(option.title, systemImage: option.systemImage).tag(option)
                                .selectionDisabled(option.isSingleton && option != kind && all.contains { $0.kind == option })
                        }
                    }
                }
                fields
            } footer: {
                Text(kind.detail)
            }
            if contribution != nil || problem != nil {
                Section {
                    if let contribution {
                        LabeledContent("This month") { MoneyText(value: contribution, currency: currency) }
                    }
                    if let problem { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(ActualTheme.negative) }
                }
            }
            if let priority = template.priority {
                Section {
                    Stepper("Priority \(priority)", value: Binding(get: { priority }, set: { template.priority = $0 }), in: 0...99)
                } footer: {
                    Text("Lower priorities are budgeted first. Cover schedule and save by date automations must share one priority.")
                }
            }
            Section("Note") {
                TextField("Note", text: $template.note, axis: .vertical)
            }
            Section {
                Button("Delete Target", systemImage: "trash", role: .destructive, action: delete)
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var fields: some View {
        switch kind {
        case .fixed:
            TargetAmountField(title: "Amount", value: $template.amount)
            Stepper(template.periodCount == 1 ? "Every \(template.periodUnit)" : "Every \(template.periodCount) \(template.periodUnit)s",
                    value: $template.periodCount, in: 1...366)
            Picker("Period", selection: $template.periodUnit) {
                Text("Day").tag("day"); Text("Week").tag("week"); Text("Month").tag("month"); Text("Year").tag("year")
            }
            DatePicker("Starting", selection: day("starting"), displayedComponents: .date)
        case .schedule:
            if targets.schedules.isEmpty {
                Text("No schedules found. Create one in Actual.").foregroundStyle(.secondary)
            } else {
                Picker("Schedule", selection: schedule) {
                    if !targets.schedules.contains(where: { $0.id == schedule.wrappedValue }) { Text("Choose").tag("") }
                    ForEach(targets.schedules) { Text($0.name).tag($0.id) }
                }
            }
            Picker("Savings mode", selection: flag("full")) {
                Text("Save up for the next occurrence").tag(false)
                Text("Cover each occurrence when it occurs").tag(true)
            }
            adjustment
        case .by:
            TargetAmountField(title: "Total amount", value: $template.amount)
            MonthPicker(title: "Target month", month: text("month"))
            Toggle("Allow early spending", isOn: $template.allowsEarlySpending)
            if template.allowsEarlySpending { MonthPicker(title: "Start spending in", month: text("from")) }
            Toggle("Repeats", isOn: $template.repeats)
            if template.repeats {
                let count = whole("repeat").wrappedValue, unit = template.bool("annual") ? "year" : "month"
                Stepper(count == 1 ? "Every \(unit)" : "Every \(count) \(unit)s", value: whole("repeat"), in: 1...120)
                Picker("Period", selection: flag("annual")) { Text("Months").tag(false); Text("Years").tag(true) }
            }
        case .percentage:
            let previous = template.bool("previous")
            Picker("Source", selection: text("category")) {
                let source = template.string("category") ?? ""
                let known = ["all income", "available funds"] + targets.incomeCategories.map(\.id)
                if !known.contains(source) || (previous && source == "available funds") { Text("Choose").tag(source) }
                Text("Total of all income").tag("all income")
                if !previous { Text("Available funds to budget").tag("available funds") }
                ForEach(targets.incomeCategories) { Text($0.name).tag($0.id) }
            }
            LabeledContent("Percentage") {
                HStack(spacing: 4) {
                    TextField("Percentage", value: number("percent"), format: .number)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                    Text("%")
                }
            }
            Picker("Percentage of", selection: Binding(get: { previous }, set: { value in
                template.set("previous", .bool(value))
                // Last month's available funds are not a source, as in Actual.
                if value, template.string("category") == "available funds" { template.set("category", "") }
            })) {
                Text("This month").tag(false); Text("Last month").tag(true)
            }
        case .historical:
            let isCopy = template.type == "copy"
            Picker("Mode", selection: Binding(get: { template.type }, set: { setHistoricalMode($0) })) {
                Text("Average of previous months").tag("average")
                Text("Copy a previous month").tag("copy")
            }
            let key = isCopy ? "lookBack" : "numMonths"
            let count = whole(key).wrappedValue
            Stepper(isCopy ? (count == 1 ? "1 month ago" : "\(count) months ago") : (count == 1 ? "Last month" : "Last \(count) months"),
                    value: whole(key), in: 1...120)
            if !isCopy { adjustment }
        case .limit:
            TargetAmountField(title: "Amount", value: $template.amount)
            Picker("Every", selection: Binding(get: { template.string("period") ?? "monthly" }, set: { period in
                template.set("period", .string(period))
                if period == "weekly", !template.has("start") { template.set("start", .string(BudgetDate.month(Date()) + "-01")) }
            })) {
                Text("Day").tag("daily"); Text("Week").tag("weekly"); Text("Month").tag("monthly")
            }
            if template.string("period") == "weekly" {
                Picker("Weekday", selection: weekday) {
                    ForEach(Array(Calendar.current.weekdaySymbols.enumerated()), id: \.offset) { Text($0.element).tag($0.offset) }
                }
            }
            Toggle("Retain existing funds over the cap", isOn: flag("hold"))
        case .refill:
            if !all.contains(where: { $0.kind == .limit }) {
                Label("Add a balance cap for this category to refill to.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(ActualTheme.warning)
                Button("Add Balance Cap", systemImage: "plus", action: addCap)
            } else {
                Text("Budgets enough to bring the balance back up to the balance cap.").foregroundStyle(.secondary)
            }
        case .remainder:
            Stepper("Weight \(whole("weight").wrappedValue)", value: whole("weight"), in: 1...100)
        case .goal:
            TargetAmountField(title: "Target amount", value: $template.amount)
        }
    }

    /// Schedule and average targets may be increased or decreased, by a percentage or an amount.
    @ViewBuilder private var adjustment: some View {
        Picker("Adjustment", selection: $template.adjustmentKind) {
            Text("None").tag(TargetTemplate.Adjustment.none)
            Text("Percentage").tag(TargetTemplate.Adjustment.percent)
            Text("Amount").tag(TargetTemplate.Adjustment.fixed)
        }
        if template.adjustmentKind != .none {
            let value = template.double("adjustment") ?? 0
            Picker("Direction", selection: Binding(get: { value >= 0 }, set: { increase in
                setAdjustment(increase ? abs(value) : -abs(value))
            })) {
                Text("Increase").tag(true); Text("Decrease").tag(false)
            }
            if template.adjustmentKind == .percent {
                LabeledContent("By") {
                    HStack(spacing: 4) {
                        TextField("Percentage", value: Binding(get: { abs(value) }, set: { setAdjustment(value < 0 ? -abs($0) : abs($0)) }), format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                        Text("%")
                    }
                }
            } else {
                TargetAmountField(title: "By", value: Binding(get: { abs(Int(value)) }, set: { setAdjustment(Double(value < 0 ? -$0 : $0)) }))
            }
        }
    }

    private func setAdjustment(_ value: Double) {
        template.set("adjustment", template.adjustmentKind == .fixed ? .number(Int(value)) : Self.json(value))
    }

    private func setHistoricalMode(_ type: String) {
        guard type != template.type else { return }
        let count = template.int(type == "copy" ? "numMonths" : "lookBack") ?? (type == "copy" ? 1 : 3)
        template.set("type", .string(type))
        template.set(type == "copy" ? "numMonths" : "lookBack", nil)
        template.set(type == "copy" ? "lookBack" : "numMonths", .number(count))
        if type == "copy" { template.adjustmentKind = .none }
    }


    private var schedule: Binding<String> {
        Binding(
            get: {
                if let id = template.string("scheduleId") { return id }
                return targets.schedules.first { $0.name == template.string("name") }?.id ?? ""
            },
            set: { id in
                guard let schedule = targets.schedules.first(where: { $0.id == id }) else { return }
                template.set("scheduleId", .string(schedule.id))
                template.set("name", .string(schedule.name))
            })
    }

    /// The weekly cap's weekday, which moves its start within the same week, as in Actual.
    private var weekday: Binding<Int> {
        let calendar = Calendar(identifier: .gregorian)
        let start = BudgetDate.date(template.string("start") ?? "") ?? Date()
        let current = calendar.component(.weekday, from: start) - 1
        return Binding(get: { current }, set: { value in
            if let moved = calendar.date(byAdding: .day, value: value - current, to: start) {
                template.set("start", .string(BudgetDate.day(moved)))
            }
        })
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { template.string(key) ?? "" }, set: { template.set(key, .string($0)) })
    }
    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { template.bool(key) }, set: { template.set(key, .bool($0)) })
    }
    private func whole(_ key: String) -> Binding<Int> {
        Binding(get: { template.int(key) ?? 1 }, set: { template.set(key, .number($0)) })
    }
    private func number(_ key: String) -> Binding<Double> {
        Binding(get: { template.double(key) ?? 0 }, set: { template.set(key, Self.json($0)) })
    }
    private func day(_ key: String) -> Binding<Date> {
        Binding(get: { BudgetDate.date(template.string(key) ?? "") ?? Date() }, set: { template.set(key, .string(BudgetDate.day($0))) })
    }
    private static func json(_ value: Double) -> JSONValue {
        if value.rounded() == value, abs(value) < 1e15 { return .number(Int(value)) }
        return .double(value)
    }
}

/// A non-negative amount entered with the calculator keypad, kept as integer minor units.
/// The amount updates whenever the entry is a complete amount or calculation.
private struct TargetAmountField: View {
    let title: String
    @Binding var value: Int
    @State private var text = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
            AmountField(label: title, text: $text)
        }
        .onAppear { text = Money.editable(value) }
        .onChange(of: text) { _, entry in
            if let amount = Money.parse(entry), amount >= 0 { value = amount }
        }
        // Another change, such as a new kind of target, replaces the entry.
        .onChange(of: value) { _, amount in
            if Money.parse(text) != amount { text = Money.editable(amount) }
        }
    }
}

/// Chooses a `yyyy-MM` month, from two years back to ten years ahead.
private struct MonthPicker: View {
    let title: String
    @Binding var month: String

    var body: some View {
        Picker(title, selection: $month) {
            if !options.contains(month) { Text("Choose").tag(month) }
            ForEach(options, id: \.self) { Text(TargetTemplate.monthLabel($0)).tag($0) }
        }
    }

    private var options: [String] {
        let now = BudgetDate.month(Date())
        var months = (-24...120).map { TargetTemplate.month(now, adding: $0) }
        if BudgetDate.date(month + "-01") != nil, !months.contains(month) { months.append(month); months.sort() }
        return months
    }
}
