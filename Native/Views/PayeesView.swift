import SwiftUI

/// Actual's payees page: rename, favorite, merge, and delete payees, one at a time or several selected,
/// see or create their rules, clear out unused ones, and set category learning.
struct PayeesView: View {
    @Environment(AppModel.self) private var model
    @State private var payees: [ManagedPayee] = []
    @State private var loadError: String?
    @State private var search = ""
    @State private var showsUnusedOnly = false
    @State private var confirmsDeleteUnused = false
    @State private var editMode = EditMode.inactive
    @State private var selection = Set<String>()
    @State private var confirmsDeleteSelected = false
    @State private var mergingSelected = false
    @State private var deleting: ManagedPayee?
    @State private var rulesFor: ManagedPayee?
    @State private var creatingRule: RuleEditRoute?

    private var shown: [ManagedPayee] {
        payees.filter { payee in
            (!showsUnusedOnly || payee.unused) && (search.isEmpty || payee.label.localizedCaseInsensitiveContains(search))
        }
    }
    private var unused: [ManagedPayee] { payees.filter(\.unused) }
    /// Transfer payees belong to accounts, so they can't be selected, as in Actual.
    private var selected: [ManagedPayee] { payees.filter { selection.contains($0.id) && !$0.isTransfer } }
    private var learnsCategories: Bool { model.overview?.format?.learnCategories ?? true }

    var body: some View {
        List(selection: $selection) {
            Group {
                if let error = model.errorMessage ?? loadError { Section { ErrorNotice(message: error) } }
                if !editMode.isEditing { settings }
                Section {
                    ForEach(shown) { payee in
                        row(payee).selectionDisabled(payee.isTransfer)
                    }
                } footer: {
                    if editMode.isEditing && payees.contains(where: \.isTransfer) {
                        Text("Transfer payees belong to accounts and can’t be selected.")
                    }
                }
            }.themedRows()
        }
        .themedPage()
        .environment(\.editMode, $editMode)
        .overlay {
            if shown.isEmpty && loadError == nil {
                ContentUnavailableView(search.isEmpty ? "No payees" : "No matching payees", systemImage: "person.2")
            }
        }
        .navigationTitle(editMode.isEditing ? selectionTitle : "Payees")
        .searchable(text: $search, prompt: "Search payees")
        .toolbar { toolbar }
        .task(id: model.dataRevision) { await load() }
        .navigationDestination(item: $rulesFor) { payee in RulesView(payee: payee) }
        .sheet(item: $creatingRule) { route in RuleEditor(rule: route.rule) }
        .sheet(isPresented: $mergingSelected) {
            MergeTargetPicker(payees: selected, title: "Keep Which Payee?",
                              footer: "The other selected payees’ transactions and rules move to the payee you keep, then they are removed.") { target in
                let merged = await model.manage("mergePayees", [
                    "targetId": .string(target.id),
                    "mergeIds": .array(selected.filter { $0.id != target.id }.map { .string($0.id) }),
                ])
                if merged { endSelecting() }
                return merged
            }
        }
        .confirmationDialog("Delete \(unused.count) unused \(unused.count == 1 ? "payee" : "payees")?",
                            isPresented: $confirmsDeleteUnused, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete(unused) } }
        } message: { Text("Rules that use them may stop matching.") }
        .confirmationDialog("Delete \(selected.count) \(selected.count == 1 ? "payee" : "payees")?",
                            isPresented: $confirmsDeleteSelected, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { if await delete(selected) { endSelecting() } }
            }
        } message: { Text("Their transactions will have no payee, and rules that use them may stop matching.") }
        .confirmationDialog("Delete \(deleting?.name ?? "this payee")?",
                            isPresented: $deleting.isPresent,
                            titleVisibility: .visible, presenting: deleting) { payee in
            Button("Delete Payee", role: .destructive) { Task { await delete([payee]) } }
        } message: { payee in
            Text(payee.unused ? "No transactions use this payee." : "Its transactions will have no payee.")
        }
    }

    @ViewBuilder private var settings: some View {
        Section {
            Toggle("Category Learning", isOn: Binding(
                get: { learnsCategories },
                set: { learn in
                    Task {
                        await model.manage("savePreference", [
                            "id": .string("learn-categories"), "value": .string(learn ? "true" : "false"),
                        ])
                    }
                }))
            .disabled(model.isBusy)
        } footer: {
            Text(learnsCategories
                 ? "As you categorize a payee’s transactions, Actual adds or updates a rule that sets the category it uses most. Turning this off keeps existing rules."
                 : "Categorizing transactions doesn’t add or change rules. Existing rules still apply.")
        }
        if !unused.isEmpty {
            Section {
                Toggle("Show only unused payees", isOn: $showsUnusedOnly)
                Button("Delete \(unused.count) Unused \(unused.count == 1 ? "Payee" : "Payees")", role: .destructive) {
                    confirmsDeleteUnused = true
                }.disabled(model.isBusy)
            } footer: { Text("Unused payees have no transactions.") }
        }
    }

    private func row(_ payee: ManagedPayee) -> some View {
        Group {
            // A link is disabled while selecting, which would dim the row; selecting needs only the row.
            if editMode.isEditing {
                PayeeRow(payee: payee, learnsCategories: learnsCategories)
            } else {
                NavigationLink {
                    PayeeDetail(payeeID: payee.id, payees: $payees) { await load() }
                } label: {
                    PayeeRow(payee: payee, learnsCategories: learnsCategories)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if !payee.isTransfer {
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = payee }
            }
            Button(payee.ruleCount > 0 ? "View Rules" : "Create Rule", systemImage: "wand.and.rays") { showRules(payee) }
                .tint(ActualTheme.accent)
        }
        .contextMenu {
            if !payee.isTransfer {
                Button(payee.favorite ? "Unfavorite" : "Favorite", systemImage: payee.favorite ? "bookmark.slash" : "bookmark") {
                    Task { await update("setPayeeFavorite", "favorite", !payee.favorite, [payee]) }
                }.disabled(model.isBusy)
                if learnsCategories {
                    Button(payee.learnCategories ? "Disable Learning" : "Enable Learning",
                           systemImage: payee.learnCategories ? "lightbulb.slash" : "lightbulb") {
                        Task { await update("setPayeeLearning", "learn", !payee.learnCategories, [payee]) }
                    }.disabled(model.isBusy)
                }
            }
            Button(payee.ruleCount > 0 ? "View Rules" : "Create Rule", systemImage: "wand.and.rays") { showRules(payee) }
            if !payee.isTransfer {
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = payee }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if editMode.isEditing {
                Button("Done") { endSelecting() }
            } else {
                Button("Select") { editMode = .active }.disabled(payees.allSatisfy(\.isTransfer))
            }
        }
        if editMode.isEditing {
            // As Actual's payee menu: each toggle sets every selected payee, unless all already have it.
            ToolbarItemGroup(placement: .bottomBar) {
                let allFavorite = !selected.isEmpty && selected.allSatisfy(\.favorite)
                Button(allFavorite ? "Unfavorite" : "Favorite", systemImage: allFavorite ? "bookmark.slash" : "bookmark") {
                    Task { await update("setPayeeFavorite", "favorite", !allFavorite, selected) }
                }.disabled(selected.isEmpty || model.isBusy)
                if learnsCategories {
                    let allLearn = !selected.isEmpty && selected.allSatisfy(\.learnCategories)
                    Button(allLearn ? "Disable Learning" : "Enable Learning",
                           systemImage: allLearn ? "lightbulb.slash" : "lightbulb") {
                        Task { await update("setPayeeLearning", "learn", !allLearn, selected) }
                    }.disabled(selected.isEmpty || model.isBusy)
                }
                Button("Merge", systemImage: "arrow.triangle.merge") { mergingSelected = true }
                    .disabled(selected.count < 2 || model.isBusy)
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive) { confirmsDeleteSelected = true }
                    .disabled(selected.isEmpty || model.isBusy)
            }
        }
    }

    private var selectionTitle: String {
        selected.isEmpty ? "Select Payees" : selected.count == 1 ? "1 Payee" : "\(selected.count) Payees"
    }

    /// As Actual's payees page: a payee's rules, or a new rule for it when it has none.
    private func showRules(_ payee: ManagedPayee) {
        if payee.ruleCount > 0 { rulesFor = payee }
        else { creatingRule = RuleEditRoute(rule: .new(payeeID: payee.id)) }
    }

    private func update(_ method: String, _ key: String, _ value: Bool, _ targets: [ManagedPayee]) async {
        await model.manage(method, ["ids": .array(targets.map { .string($0.id) }), key: .bool(value)])
    }

    @discardableResult
    private func delete(_ targets: [ManagedPayee]) async -> Bool {
        await model.manage("deletePayees", ["ids": .array(targets.map { .string($0.id) })])
    }

    private func endSelecting() {
        selection = []
        editMode = .inactive
    }

    private func load() async {
        do {
            payees = try await model.managedPayees()
            selection.formIntersection(payees.map(\.id))
            loadError = nil
        } catch { loadError = error.localizedDescription }
    }
}

/// A payee's row: favorite, name, and whether it is unused, doesn't learn categories, or has rules.
private struct PayeeRow: View {
    let payee: ManagedPayee
    let learnsCategories: Bool

    var body: some View {
        HStack {
            if payee.favorite {
                Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(ActualTheme.accent)
                    .accessibilityLabel("Favorite")
            }
            Text(payee.label).foregroundStyle(payee.isTransfer ? Color.secondary : Color.primary)
            Spacer()
            if payee.unused { Text("Unused").font(.caption).foregroundStyle(.secondary) }
            if learnsCategories && !payee.learnCategories && !payee.isTransfer {
                Image(systemName: "lightbulb.slash").font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Category learning off")
            }
            if payee.ruleCount > 0 {
                Text(payee.ruleCount == 1 ? "1 rule" : "\(payee.ruleCount) rules")
                    .font(.caption).foregroundStyle(ActualTheme.accent)
            }
        }
    }
}

/// One payee: rename, favorite, turn category learning on or off, see or create its rules,
/// merge into another payee, or delete. A transfer payee's rules are all that can be managed.
private struct PayeeDetail: View {
    let payeeID: String
    @Binding var payees: [ManagedPayee]
    var reload: () async -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var merging = false
    @State private var confirmsDelete = false
    @State private var creatingRule: RuleEditRoute?

    private var payee: ManagedPayee? { payees.first { $0.id == payeeID } }

    var body: some View {
        ThemedForm {
            if let payee {
                Section {
                    if payee.isTransfer {
                        LabeledContent("Account", value: payee.name)
                    } else {
                        Button { renaming = true } label: { LabeledContent("Name", value: payee.name) }
                    }
                    LabeledContent("Transactions", value: payee.unused ? "None" : "Yes")
                } footer: {
                    if payee.isTransfer {
                        Text("This payee stands for an account. Rename or close it from Accounts.")
                    }
                }
                if !payee.isTransfer {
                    Section {
                        Toggle("Favorite", isOn: Binding(
                            get: { payee.favorite },
                            set: { favorite in Task { await set("setPayeeFavorite", "favorite", favorite) } }))
                    } footer: {
                        Text("Favorites are suggested first when you choose a payee.")
                    }
                    // As in Actual, a payee's learning can be changed only while the budget learns categories.
                    if model.overview?.format?.learnCategories ?? true {
                        Section {
                            Toggle("Learn Categories", isOn: Binding(
                                get: { payee.learnCategories },
                                set: { learn in Task { await set("setPayeeLearning", "learn", learn) } }))
                        } footer: {
                            Text("Categorizing this payee’s transactions updates the rule that sets its category.")
                        }
                    }
                }
                Section {
                    if payee.ruleCount > 0 {
                        NavigationLink { RulesView(payee: payee) } label: {
                            LabeledContent("Rules", value: "\(payee.ruleCount)")
                        }
                    }
                    Button("Create Rule", systemImage: "wand.and.rays") {
                        creatingRule = RuleEditRoute(rule: .new(payeeID: payeeID))
                    }
                } footer: {
                    Text("A new rule matches this payee, and sets a category you choose.")
                }
                if !payee.isTransfer {
                    Section {
                        Button("Merge into Another Payee", systemImage: "arrow.triangle.merge") { merging = true }
                    } footer: {
                        Text("Merging moves this payee’s transactions and rules to the payee you choose, then removes this one.")
                    }
                    Section {
                        Button("Delete Payee", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                    } footer: {
                        Text(payee.unused ? "No transactions use this payee." : "Its transactions will have no payee.")
                    }
                }
            }
            if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
        }
        .disabled(model.isBusy)
        .navigationTitle(payee?.label ?? "Payee").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $creatingRule) { route in RuleEditor(rule: route.rule) }
        .sheet(isPresented: $renaming) {
            NameSheet(title: "Rename Payee", initial: payee?.name ?? "") { name in
                let renamed = await model.manage("renamePayee", ["id": .string(payeeID), "name": .string(name)])
                if renamed { await reload() }
                return renamed
            }
        }
        .sheet(isPresented: $merging) {
            MergeTargetPicker(payees: payees.filter { $0.id != payeeID && !$0.isTransfer }) { target in
                let merged = await model.manage("mergePayees", [
                    "targetId": .string(target.id), "mergeIds": .array([.string(payeeID)]),
                ])
                if merged { await reload(); dismiss() }
                return merged
            }
        }
        .confirmationDialog("Delete \(payee?.name ?? "this payee")?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Payee", role: .destructive) {
                Task {
                    if await model.manage("deletePayees", ["ids": .array([.string(payeeID)])]) { await reload(); dismiss() }
                }
            }
        }
    }

    private func set(_ method: String, _ key: String, _ value: Bool) async {
        if await model.manage(method, ["ids": .array([.string(payeeID)]), key: .bool(value)]) { await reload() }
    }
}

/// Chooses the payee to keep when merging.
private struct MergeTargetPicker: View {
    let payees: [ManagedPayee]
    var title = "Merge Into"
    var footer: String? = nil
    let merge: (ManagedPayee) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                Group {
                    Section {
                        ForEach(payees.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { payee in
                            Button(payee.name) { Task { if await merge(payee) { dismiss() } } }
                                .foregroundStyle(Color.primary).disabled(model.isBusy)
                        }
                    } footer: {
                        if let footer { Text(footer) }
                    }
                    if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
                }.themedRows()
            }
            .themedPage()
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search payees")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
