import SwiftUI

/// Edits a dashboard widget's saved settings, as its page and card menu do in Actual:
/// its name, range, filters, and options, or a text widget's Markdown.
struct ReportWidgetEditor: View {
    let widget: ReportWidget
    let earliestMonth: String
    /// Called with the saved name once the widget is saved.
    var onSaved: (String) -> Void = { _ in }
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var saved: ReportWidgetSettings?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            if let saved {
                ReportWidgetForm(widget: widget, saved: saved, earliestMonth: earliestMonth, onSaved: onSaved)
            } else {
                ReportPlaceholder(error: error, height: 240) { Task { await load() } }
                    .navigationTitle(widget.editTitle).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            }
        }
        .task { await load() }
    }

    /// Reads the widget as it is now, so another device's changes are not edited over.
    private func load() async {
        do {
            saved = try await model.reportSettings(widget.id)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension ReportWidget {
    var editTitle: String { kind == .markdown ? "Edit Text" : "Edit Widget" }
}

private struct ReportWidgetForm: View {
    let widget: ReportWidget
    let saved: ReportWidgetSettings
    let earliestMonth: String
    let onSaved: (String) -> Void
    private let savedRange: ReportRangeDraft?
    @State private var draft: ReportWidgetSettings
    @State private var range: ReportRangeDraft?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    init(widget: ReportWidget, saved: ReportWidgetSettings, earliestMonth: String, onSaved: @escaping (String) -> Void) {
        self.widget = widget
        self.saved = saved
        self.earliestMonth = earliestMonth
        self.onSaved = onSaved
        savedRange = saved.timeFrame.map {
            ReportRangeDraft($0, earliestMonth: earliestMonth, oneMonth: [.cashFlow, .summary, .calendar].contains(widget.kind))
        }
        _draft = State(initialValue: saved)
        _range = State(initialValue: savedRange)
    }

    /// What saving would change. A range counts once it differs from the saved one.
    private var changes: [String: JSONValue] {
        draft.changes(from: saved, timeFrame: range == savedRange ? nil : range?.timeFrame(earliestMonth: earliestMonth))
    }

    var body: some View {
        Form {
            if widget.kind == .markdown {
                text
            } else {
                Section("Name") {
                    TextField(ReportWidget.defaultTitle(saved.type), text: $draft.name)
                        .accessibilityLabel("Name")
                }
                if let savedRange { rangeSection(savedRange) }
                options
                ReportFilterSection(
                    title: "Filters", conditions: $draft.conditions, op: $draft.conditionsOp,
                    // Spending compares whole months, so Actual offers it no date filter.
                    fields: RuleItem.filterFields.filter { widget.kind != .spending || $0 != "date" },
                    footer: "Only transactions matching the filters count.")
                if draft.summaryType == "percentage" { divisor }
            }
            if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
        }
        .disabled(model.isBusy)
        .navigationTitle(widget.editTitle).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.bold().disabled(changes.isEmpty)
            }
        }
    }

    private func save() {
        let changes = changes
        Task {
            guard await model.saveReportWidget(saved.id, changes: changes) else { return }
            // Actual gives a widget whose name is cleared its default name.
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            onSaved(name.isEmpty ? ReportWidget.defaultTitle(saved.type) : name)
            dismiss()
        }
    }

    // MARK: Range

    private func rangeSection(_ savedRange: ReportRangeDraft) -> some View {
        let range = Binding(get: { self.range ?? savedRange }, set: { self.range = $0 })
        let oneMonth = [.cashFlow, .summary, .calendar].contains(widget.kind)
        let current = BudgetDate.month(Date())
        let months = ReportDate.months(between: min(earliestMonth, range.wrappedValue.start),
                                       and: max(current, range.wrappedValue.end))
        return Section {
            Picker("Range", selection: range.kind) {
                if savedRange.kind == .saved, let frame = saved.timeFrame {
                    Text(ReportDate.describe(frame)).tag(ReportRangeDraft.Kind.saved)
                }
                ForEach(ReportRangePreset.available(oneMonth: oneMonth)) { preset in
                    Text(preset.title).tag(ReportRangeDraft.Kind.preset(preset))
                }
                Text("Last months…").tag(ReportRangeDraft.Kind.live)
                Text("Fixed months…").tag(ReportRangeDraft.Kind.fixed)
            }
            switch range.wrappedValue.kind {
            case .live:
                Stepper(range.wrappedValue.liveMonths == 1 ? "This month" : "Last \(range.wrappedValue.liveMonths) months",
                        value: range.liveMonths, in: 1...120)
            case .fixed:
                MonthField(title: "From", months: months, month: Binding(get: { range.wrappedValue.start }, set: { month in
                    range.wrappedValue.start = month
                    if month > range.wrappedValue.end { range.wrappedValue.end = month }
                }))
                MonthField(title: "To", months: months, month: Binding(get: { range.wrappedValue.end }, set: { month in
                    range.wrappedValue.end = month
                    if month < range.wrappedValue.start { range.wrappedValue.start = month }
                }))
            default: EmptyView()
            }
        } header: { Text("Range") } footer: {
            switch range.wrappedValue.kind {
            case .fixed: Text("The report stays on these months.")
            case .live: Text("Ends with the current month and moves with it.")
            case .saved: Text("This range was set in Actual. Choose another to change it.")
            case .preset: Text("The range moves with the current date.")
            }
        }
    }

    // MARK: Options

    @ViewBuilder private var options: some View {
        switch widget.kind {
        case .netWorth:
            Section("Graph") {
                Picker("Interval", selection: Binding(get: { draft.interval ?? "Monthly" }, set: { draft.interval = $0 })) {
                    ForEach(["Daily", "Weekly", "Monthly", "Yearly"], id: \.self) { Text($0).tag($0) }
                }
                Picker("Show", selection: Binding(get: { draft.graphMode ?? "trend" }, set: { draft.graphMode = $0 })) {
                    Text("Trend").tag("trend")
                    Text("Stacked by account").tag("stacked")
                }
            }
        case .cashFlow:
            Section {
                Toggle("Show balance", isOn: Binding(get: { draft.showBalance ?? true }, set: { draft.showBalance = $0 }))
            } footer: { Text("The running balance on the report’s page.") }
        case .spending: comparison
        case .summary:
            Section {
                Picker("Show as", selection: Binding(get: { draft.summaryType ?? "sum" }, set: { draft.summaryType = $0 })) {
                    ForEach(ReportWidgetSettings.summaryTypes, id: \.id) { Text($0.title).tag($0.id) }
                }
            }
        default: EmptyView()
        }
    }

    /// Spending.tsx's compare controls: a month, and what to compare it with.
    private var comparison: some View {
        let current = BudgetDate.month(Date())
        let months = ReportDate.months(between: min(earliestMonth, draft.compare ?? current, draft.compareTo ?? current),
                                       and: current)
        let mode = draft.spendingMode ?? .singleMonth
        return Section {
            Picker("Month", selection: $draft.compare) {
                Text("Current month").tag(String?.none)
                ForEach(months, id: \.self) { Text(ReportDate.month($0)).tag(Optional($0)) }
            }
            Picker("Compare to", selection: Binding(get: { mode }, set: { draft.spendingMode = $0 })) {
                ForEach(SpendingReport.Mode.allCases) { Text($0.title).tag($0) }
            }
            switch mode {
            case .singleMonth:
                Picker("Other month", selection: $draft.compareTo) {
                    Text("The month before").tag(String?.none)
                    ForEach(months, id: \.self) { Text(ReportDate.month($0)).tag(Optional($0)) }
                }
            case .average:
                Picker("Average of", selection: Binding(
                    get: { draft.averageRange ?? SpendingReport.AverageRange.options[0] }, set: { draft.averageRange = $0 })) {
                    ForEach(SpendingReport.AverageRange.options, id: \.self) { Text($0.optionTitle).tag($0) }
                }
            case .budget: EmptyView()
            }
        } header: { Text("Comparison") } footer: {
            Text(draft.compare == nil ? "The report follows the current month." : "The report stays on the chosen month.")
        }
    }

    /// A percentage divides the filtered total by the total of these filters.
    @ViewBuilder private var divisor: some View {
        ReportFilterSection(
            title: "Divided by",
            conditions: Binding(get: { draft.divisorConditions ?? [] }, set: { draft.divisorConditions = $0 }),
            op: Binding(get: { draft.divisorConditionsOp ?? "and" }, set: { draft.divisorConditionsOp = $0 }),
            footer: "The percentage is the filtered total divided by the total matching these filters.")
        Section {
            Toggle("All time divisor", isOn: Binding(
                get: { draft.divisorAllTimeDateRange ?? false }, set: { draft.divisorAllTimeDateRange = $0 }))
        } footer: { Text("Divide by the total for all time instead of the range.") }
    }

    // MARK: Text

    @ViewBuilder private var text: some View {
        Section {
            TextEditor(text: Binding(get: { draft.content ?? "" }, set: { draft.content = $0 }))
                .frame(minHeight: 220)
                .accessibilityLabel("Text")
        } header: { Text("Text") } footer: {
            Text("Markdown: # headings, lists, **bold**, *italics*, and links.")
        }
        Section {
            Picker("Alignment", selection: Binding(get: { draft.textAlign ?? "left" }, set: { draft.textAlign = $0 })) {
                Text("Left").tag("left")
                Text("Center").tag("center")
                Text("Right").tag("right")
            }.pickerStyle(.segmented)
        } header: { Text("Text position") }
    }
}

extension SpendingReport.AverageRange {
    /// spendingAverageRange.ts option labels.
    var optionTitle: String {
        switch mode {
        case "year-to-date": "Year to date"
        case "all-time": "All time"
        default: "Last \(months ?? 3) months"
        }
    }
}

/// Chooses one of the listed `yyyy-MM` months.
private struct MonthField: View {
    let title: String
    let months: [String]
    @Binding var month: String

    var body: some View {
        Picker(title, selection: $month) {
            if !months.contains(month) { Text(ReportDate.month(month)).tag(month) }
            ForEach(months, id: \.self) { Text(ReportDate.month($0)).tag($0) }
        }
    }
}

/// A widget's filters: conditions as Actual's filter menu saves them, matching all or any.
struct ReportFilterSection: View {
    let title: String
    @Binding var conditions: [RuleItem]
    @Binding var op: String
    var fields = RuleItem.filterFields
    var footer: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let describer = RuleDescriber(model: model)
        Section {
            if conditions.count > 1 {
                Picker("Match", selection: $op) {
                    Text("All filters").tag("and")
                    Text("Any filter").tag("or")
                }
            }
            ForEach($conditions) { $item in
                if item.isEditableFilter {
                    NavigationLink { ConditionEditor(item: $item, fields: fields, title: "Filter") } label: {
                        Text(describer.condition(item).capitalizedFirst).foregroundStyle(Color.primary)
                    }
                } else {
                    // Kept as saved; it can be removed but not changed here.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.customName ?? describer.condition(item).capitalizedFirst)
                        Text(item.customName == nil ? "Change this filter in Actual web or desktop."
                             : "A named filter from Actual, which reports do not apply.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { conditions.remove(atOffsets: $0) }
            Button("Add Filter", systemImage: "plus") {
                conditions.append(.condition(field: fields.contains("category") ? "category" : fields[0]))
            }
        } header: { Text(title) } footer: { Text(footer) }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
