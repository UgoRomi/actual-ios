import SwiftUI

extension Color {
    /// A #RRGGBB color, as Actual stores tag colors.
    init?(hex: String?) {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    /// This color as #RRGGBB.
    var hex: String {
        let resolved = UIColor(self).cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
        let parts = (resolved?.components ?? [0, 0, 0]).map { Int(($0 * 255).rounded()).clamped(to: 0...255) }
        return String(format: "#%02X%02X%02X", parts[0], parts[safe: 1] ?? 0, parts[safe: 2] ?? 0)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

/// Notes with their #tags in each tag's color, as Actual's register shows them.
struct NotesText: View {
    let notes: String
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        let tags = Set(NoteTags.extract(notes))
        guard !tags.isEmpty else { return AttributedString(notes) }
        let colors = Dictionary((model.overview?.tags ?? []).map { ($0.tag, $0.color) }, uniquingKeysWith: { a, _ in a })
        var result = AttributedString()
        // Words keep their spacing; a word that is a #tag gets the tag's color.
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            var piece = AttributedString(word)
            let name = word.hasPrefix("#") && !word.hasPrefix("##") ? String(word.dropFirst()) : ""
            if tags.contains(name) {
                piece.foregroundColor = Color(hex: colors[name] ?? nil) ?? ActualTheme.accent
                piece.font = .caption.weight(.semibold)
            }
            result += piece
            word = ""
        }
        for character in notes {
            if character.isWhitespace { flush(); result += AttributedString(String(character)) }
            else { word.append(character) }
        }
        flush()
        return result
    }
}

/// Actual's tags page: colors, descriptions, and hiding for #tags in notes.
struct TagsView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var search = ""

    private var tags: [Tag] {
        (model.overview?.tags ?? []).filter { search.isEmpty || $0.tag.localizedCaseInsensitiveContains(search) }
    }
    /// How many transactions use each tag.
    private var counts: [String: Int] {
        var counts: [String: Int] = [:]
        for transaction in model.transactions {
            let splitNotes = (transaction.splits ?? []).map(\.notes)
            for tag in Set(([transaction.notes] + splitNotes).flatMap(NoteTags.extract)) { counts[tag, default: 0] += 1 }
        }
        return counts
    }

    var body: some View {
        let counts = counts
        ThemedList {
            if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
            Section {
                ForEach(tags) { tag in
                    NavigationLink { TagEditor(tagID: tag.id) } label: {
                        HStack {
                            Circle().fill(Color(hex: tag.color) ?? ActualTheme.accent).frame(width: 12, height: 12)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("#\(tag.tag)").foregroundStyle(tag.hidden ? .secondary : .primary)
                                if let description = tag.description, !description.isEmpty {
                                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if tag.hidden { Image(systemName: "eye.slash").foregroundStyle(.secondary) }
                            Text("\(counts[tag.tag] ?? 0)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Add #tags to a transaction’s notes, such as #vacation. Tags here give them a color and description.")
            }
            Section {
                Button("Find Existing Tags", systemImage: "magnifyingglass") {
                    Task { await model.manage("discoverTags", [:]) }
                }.disabled(model.isBusy)
            } footer: { Text("Adds every #tag already used in your notes.") }
        }
        .overlay {
            if tags.isEmpty && search.isEmpty {
                ContentUnavailableView("No tags yet", systemImage: "number",
                                       description: Text("Add #tags to notes, or add a tag here."))
            }
        }
        .navigationTitle("Tags")
        .searchable(text: $search, prompt: "Search tags")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add tag", systemImage: "plus") { adding = true }.disabled(model.isBusy)
            }
        }
        .sheet(isPresented: $adding) {
            NameSheet(title: "New Tag", action: "Add") { name in
                await model.manage("createTag", ["tag": .string(name)])
            }
        }
    }
}

/// One tag: rename, color, description, hiding, its transactions, or deletion.
private struct TagEditor: View {
    let tagID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var description = ""
    @State private var color = ActualTheme.accent
    @State private var confirmsDelete = false
    @State private var loaded = false
    @State private var colorSave: Task<Void, Never>?

    private var tag: Tag? { model.overview?.tags.first { $0.id == tagID } }

    var body: some View {
        ThemedForm {
            if let tag {
                Section {
                    Button { renaming = true } label: { LabeledContent("Name", value: "#\(tag.tag)") }
                    ColorPicker("Color", selection: $color, supportsOpacity: false)
                    TextField("Description", text: $description, axis: .vertical)
                        .onSubmit(saveDescription)
                    Toggle("Hidden", isOn: Binding(get: { tag.hidden }, set: { hidden in
                        Task { await model.manage("updateTag", ["id": .string(tagID), "hidden": .bool(hidden)]) }
                    }))
                } footer: {
                    Text("Renaming also changes the tag in every transaction’s notes, as in Actual. Hidden tags keep their color but leave tag suggestions.")
                }
                Section {
                    NavigationLink {
                        TransactionsView(accountName: "#\(tag.tag)", embedsNavigation: false, tag: tag.tag)
                    } label: { Label("Transactions", systemImage: "list.bullet.rectangle") }
                }
                Section {
                    Button("Delete Tag", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                } footer: { Text("The #tag stays in notes; only its color and description are removed.") }
            }
            if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
        }
        .disabled(model.isBusy)
        .navigationTitle(tag.map { "#\($0.tag)" } ?? "Tag").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded, let tag else { return }
            loaded = true
            description = tag.description ?? ""
            color = Color(hex: tag.color) ?? ActualTheme.accent
        }
        .onChange(of: color) { _, newColor in
            guard loaded else { return }
            colorSave?.cancel()
            colorSave = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await model.manage("updateTag", ["id": .string(tagID), "color": .string(newColor.hex)])
            }
        }
        .onDisappear(perform: saveDescription)
        .sheet(isPresented: $renaming) {
            NameSheet(title: "Rename Tag", initial: tag?.tag ?? "") { name in
                await model.manage("updateTag", ["id": .string(tagID), "tag": .string(name)])
            }
        }
        .confirmationDialog("Delete this tag?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Tag", role: .destructive) {
                Task { if await model.manage("deleteTag", ["id": .string(tagID)]) { dismiss() } }
            }
        }
    }

    private func saveDescription() {
        guard let tag, description != (tag.description ?? "") else { return }
        let value = description
        Task { await model.manage("updateTag", ["id": .string(tagID), "description": .string(value)]) }
    }
}
