import SwiftUI
import UniformTypeIdentifiers

/// Imports a transaction file into an account, as Actual's import dialog does.
struct ImportSheet: View {
    let accountID: String
    let fileName: String
    let data: Data
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var preview: ImportPreview?
    @State private var settings: ImportPreview.Settings?
    @State private var selected: Set<String> = []
    @State private var loadError: String?
    @State private var loading = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                if let loadError { Section { ErrorNotice(message: loadError) } }
                if let preview {
                    if preview.fileType == "csv", settings != nil { csvSettings(preview) }
                    else if preview.fileType == "qif", settings != nil { dateFormatSection }
                    Section {
                        Toggle("Flip amounts", isOn: binding(\.flipAmount))
                    } footer: { Text("Use this when payments appear as deposits.") }
                    if !preview.problems.isEmpty {
                        Section("Skipped rows") {
                            ForEach(preview.problems.prefix(5), id: \.self) { Text($0).font(.caption) }
                            if preview.problems.count > 5 { Text("And \(preview.problems.count - 5) more").font(.caption) }
                        }
                    }
                    Section {
                        ForEach(preview.transactions) { row in
                            Button { toggle(row) } label: { rowView(row) }.buttonStyle(.plain)
                        }
                    } header: {
                        Text("\(selected.count) of \(preview.transactions.count) selected")
                    } footer: {
                        Text("Rows matching an existing transaction update it instead of adding a duplicate, as in Actual. Rules run on imported transactions.")
                    }
                } else if loadError == nil {
                    Section { ProgressView("Reading \(fileName)…") }
                }
                if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
            }
            .disabled(loading || model.isBusy)
            .navigationTitle("Import").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: commit).bold().disabled(selected.isEmpty || loading || model.isBusy)
                }
            }
            .task { await load() }
            .onChange(of: settings) { old, new in if old != nil, new != nil { Task { await load() } } }
            .alert("Imported", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil; dismiss() } })) {
                Button("OK") {}
            } message: { Text(result ?? "") }
        }
    }

    @ViewBuilder private func csvSettings(_ preview: ImportPreview) -> some View {
        Section {
            Toggle("First row is headers", isOn: binding(\.hasHeaderRow))
            Picker("Separator", selection: binding(\.delimiter)) {
                Text("Comma").tag(",")
                Text("Semicolon").tag(";")
                Text("Tab").tag("\t")
                Text("Pipe").tag("|")
            }
        } header: { Text("File") }
        Section {
            columnPicker("Date", \.date, preview)
            columnPicker("Payee", \.payee, preview)
            columnPicker("Notes", \.notes, preview)
            columnPicker("Category", \.category, preview)
            Toggle("Separate inflow and outflow columns", isOn: binding(\.splitMode))
            if settings?.splitMode == true {
                columnPicker("Outflow", \.outflow, preview)
                columnPicker("Inflow", \.inflow, preview)
            } else {
                columnPicker("Amount", \.amount, preview)
            }
        } header: { Text("Columns") }
        dateFormatSection
    }

    private var dateFormatSection: some View {
        Section {
            Picker("Date format", selection: Binding(
                get: { settings?.dateFormat ?? "" },
                set: { settings?.dateFormat = $0 })) {
                ForEach(ImportPreview.dateFormats, id: \.self) { Text($0.uppercased()).tag($0) }
            }
        }
    }

    private func columnPicker(_ title: String, _ key: WritableKeyPath<ImportPreview.Settings.Mapping, String?>,
                              _ preview: ImportPreview) -> some View {
        Picker(title, selection: Binding(
            get: { settings?.mapping?[keyPath: key] ?? "" },
            set: { value in
                var mapping = settings?.mapping ?? .init()
                mapping[keyPath: key] = value.isEmpty ? nil : value
                settings?.mapping = mapping
            })) {
            Text("None").tag("")
            ForEach(preview.columns, id: \.self) { column in
                Text(preview.settings.hasHeaderRow ? column : "Column \(column)").tag(column)
            }
        }
    }

    private func binding<Value>(_ key: WritableKeyPath<ImportPreview.Settings, Value>) -> Binding<Value> where Value: Equatable {
        Binding(get: { settings![keyPath: key] }, set: { settings?[keyPath: key] = $0 })
    }

    private func rowView(_ row: ImportPreview.Row) -> some View {
        HStack(spacing: 12) {
            Image(systemName: selected.contains(row.id) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected.contains(row.id) ? ActualTheme.purple : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.payee.isEmpty ? "No payee" : row.payee)
                HStack(spacing: 6) {
                    Text(BudgetDate.display(row.date))
                    if row.ignored { Text("· Already imported") }
                    else if row.existing { Text("· Updates a match").foregroundStyle(.orange) }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            MoneyText(value: row.amount, currency: model.currency, positiveColor: .green)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected.contains(row.id) ? .isSelected : [])
    }

    private func toggle(_ row: ImportPreview.Row) {
        if selected.contains(row.id) { selected.remove(row.id) } else { selected.insert(row.id) }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let loaded = try await model.prepareImport(accountID: accountID, fileName: fileName, data: data,
                                                       settings: settings)
            preview = loaded
            if settings == nil { settings = loaded.settings }
            // As Actual's dialog, rows it would skip start unselected.
            selected = Set(loaded.transactions.filter { !$0.ignored }.map(\.id))
            loadError = nil
        } catch { loadError = error.localizedDescription }
    }

    private func commit() {
        guard let preview, let settings else { return }
        let rows = preview.transactions.filter { selected.contains($0.id) }.map { JSONValue.object($0.payload) }
        Task {
            if let counts = await model.commitImport(accountID: accountID, fileName: fileName,
                                                     transactions: rows, settings: settings) {
                result = "\(counts.added) added, \(counts.updated) updated."
            }
        }
    }
}

extension UTType {
    /// The files Actual imports: OFX/QFX, QIF, CSV/TSV, and CAMT XML.
    static let importable: [UTType] = [.commaSeparatedText, .tabSeparatedText, .xml, .text, .data]
        + ["ofx", "qfx", "qif"].compactMap { UTType(filenameExtension: $0) }
}
