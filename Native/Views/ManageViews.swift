import SwiftUI

/// Asks for a name, as Actual's new-category, new-group, and rename prompts do.
struct NameSheet: View {
    let title: String
    var initial = ""
    var action = "Save"
    let save: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var validation: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Name", text: $name).focused($focused).submitLabel(.done).onSubmit(submit) }
                if let validation { Section { Text(validation).foregroundStyle(.red) } }
                if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.isBusy) }
                ToolbarItem(placement: .confirmationAction) { Button(action, action: submit).bold().disabled(model.isBusy) }
            }
            .onAppear { name = initial; focused = true }
        }
        .presentationDetents([.medium])
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // As in Actual: "Name is required."
        guard !trimmed.isEmpty else { validation = "Name is required."; return }
        validation = nil
        Task { if await save(trimmed) { dismiss() } }
    }
}

/// Edits the notes Actual keeps for a category, group, account, or month.
struct NotesSheet: View {
    /// Actual's notes ID: a category or group ID, `account-<id>`, or `budget-<month>`.
    let id: String
    let title: String
    let initial: String
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section { TextEditor(text: $notes).frame(minHeight: 180) }
                if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.isBusy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await model.manage("saveNotes", ["id": .string(id), "note": .string(notes)]) { dismiss() }
                        }
                    }.bold().disabled(model.isBusy)
                }
            }
            .onAppear { notes = initial }
        }
    }
}

/// Where a deleted category's transactions and budgets go, as Actual's delete dialog asks.
struct DeleteTransferForm: View {
    let title: String
    let message: String
    /// Categories of the same kind, other than those being deleted.
    let candidates: [CategoryGroup]
    let delete: (String) async -> Bool
    @Environment(AppModel.self) private var model
    @State private var selection: String?

    var body: some View {
        Form {
            Section { Text(message).font(.subheadline) }
            ForEach(candidates) { group in
                Section(group.name) {
                    ForEach(group.categories) { category in
                        Button { selection = category.id } label: {
                            CheckRow(title: category.name, selected: selection == category.id)
                        }
                    }
                }
            }
            if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Delete", role: .destructive) {
                    if let selection { Task { _ = await delete(selection) } }
                }.disabled(selection == nil || model.isBusy)
            }
        }
    }
}

/// Rename, notes, visibility, order, group, and deletion for one category,
/// as Actual's mobile category menu offers them.
struct CategoryManageForm: View {
    let categoryID: String
    /// Called after the category is deleted, to close what showed it.
    var onDeleted: () -> Void
    @Environment(AppModel.self) private var model
    @State private var renaming = false
    @State private var editingNotes = false
    @State private var confirmsDelete = false
    @State private var choosesTransfer = false

    private var groups: [CategoryGroup] { model.budget?.groups ?? [] }
    private var group: CategoryGroup? { groups.first { $0.categories.contains { $0.id == categoryID } } }
    private var category: BudgetCategory? { group?.categories.first { $0.id == categoryID } }

    var body: some View {
        Form {
            if let category, let group {
                Section {
                    Button { renaming = true } label: { LabeledContent("Name", value: category.name) }
                    Button { editingNotes = true } label: {
                        LabeledContent("Notes") {
                            Text(category.notes?.isEmpty == false ? category.notes! : "None").lineLimit(2)
                        }
                    }
                    Toggle("Hidden", isOn: Binding(get: { category.hidden }, set: { hidden in
                        Task { await model.manage("updateCategory", ["id": .string(categoryID), "hidden": .bool(hidden)]) }
                    }))
                    Picker("Group", selection: Binding(get: { group.id }, set: { groupID in
                        Task { await model.manage("updateCategory", ["id": .string(categoryID), "groupId": .string(groupID)]) }
                    })) {
                        ForEach(groups.filter { $0.isIncome == group.isIncome }) { Text($0.name).tag($0.id) }
                    }
                } footer: {
                    Text("Hidden categories keep their budgets and transactions but are left out of the budget and category lists.")
                }
                Section("Order") {
                    let index = group.categories.firstIndex { $0.id == categoryID } ?? 0
                    Button("Move Up", systemImage: "arrow.up") { move(before: group.categories[index - 1].id) }
                        .disabled(index == 0)
                    Button("Move Down", systemImage: "arrow.down") {
                        move(before: index + 2 < group.categories.count ? group.categories[index + 2].id : nil)
                    }.disabled(index >= group.categories.count - 1)
                }
                Section {
                    Button("Delete Category", systemImage: "trash", role: .destructive) { startDelete() }
                }
                if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
            }
        }
        .disabled(model.isBusy)
        .navigationTitle(category?.name ?? "Category").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $renaming) {
            NameSheet(title: "Rename Category", initial: category?.name ?? "") { name in
                await model.manage("updateCategory", ["id": .string(categoryID), "name": .string(name)])
            }
        }
        .sheet(isPresented: $editingNotes) {
            NotesSheet(id: categoryID, title: category?.name ?? "Notes", initial: category?.notes ?? "")
        }
        .confirmationDialog("Delete this category?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Category", role: .destructive) { Task { await delete(transferTo: nil) } }
        } message: { Text("It has no transactions or budgets, so nothing else changes.") }
        .navigationDestination(isPresented: $choosesTransfer) {
            DeleteTransferForm(
                title: "Delete Category",
                message: "This category has transactions or budgets. Choose a category to receive them.",
                candidates: candidates) { await delete(transferTo: $0) }
        }
    }

    private var candidates: [CategoryGroup] {
        let isIncome = group?.isIncome ?? false
        return groups.filter { $0.isIncome == isIncome }.compactMap { group in
            var kept = group
            kept.categories = group.categories.filter { $0.id != categoryID }
            return kept.categories.isEmpty ? nil : kept
        }
    }

    private func move(before target: String?) {
        var arguments: [String: JSONValue] = ["id": .string(categoryID)]
        if let target { arguments["targetId"] = .string(target) }
        Task { await model.manage("moveCategory", arguments) }
    }

    private func startDelete() {
        Task {
            do {
                if try await model.categoryNeedsTransfer(categoryID) { choosesTransfer = true } else { confirmsDelete = true }
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    @discardableResult
    private func delete(transferTo target: String?) async -> Bool {
        var arguments: [String: JSONValue] = ["id": .string(categoryID)]
        if let target { arguments["transferId"] = .string(target) }
        let deleted = await model.manage("deleteCategory", arguments)
        if deleted { onDeleted() }
        return deleted
    }
}

/// Rename, notes, visibility, order, new categories, and deletion for a category group.
struct GroupManageSheet: View {
    let groupID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var addingCategory = false
    @State private var editingNotes = false
    @State private var confirmsDelete = false
    @State private var choosesTransfer = false

    private var groups: [CategoryGroup] { model.budget?.groups ?? [] }
    private var group: CategoryGroup? { groups.first { $0.id == groupID } }
    /// Groups of the same kind, in order, for moving up and down.
    private var siblings: [CategoryGroup] { groups.filter { $0.isIncome == group?.isIncome } }

    var body: some View {
        NavigationStack {
            Form {
                if let group {
                    Section {
                        Button { renaming = true } label: { LabeledContent("Name", value: group.name) }
                        Button { editingNotes = true } label: {
                            LabeledContent("Notes") {
                                Text(group.notes?.isEmpty == false ? group.notes! : "None").lineLimit(2)
                            }
                        }
                        if !group.isIncome {
                            Toggle("Hidden", isOn: Binding(get: { group.hidden }, set: { hidden in
                                Task { await model.manage("updateCategoryGroup", ["id": .string(groupID), "hidden": .bool(hidden)]) }
                            }))
                        }
                    }
                    Section("Categories") {
                        Button("Add Category", systemImage: "plus") { addingCategory = true }
                    }
                    if !group.isIncome {
                        Section("Order") {
                            let index = siblings.firstIndex { $0.id == groupID } ?? 0
                            Button("Move Up", systemImage: "arrow.up") { move(before: siblings[index - 1].id) }
                                .disabled(index == 0)
                            Button("Move Down", systemImage: "arrow.down") {
                                move(before: index + 2 < siblings.count ? siblings[index + 2].id : nil)
                            }.disabled(index >= siblings.count - 1)
                        }
                        Section {
                            Button("Delete Group", systemImage: "trash", role: .destructive) { startDelete() }
                        }
                    }
                    if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
                }
            }
            .disabled(model.isBusy)
            .navigationTitle(group?.name ?? "Group").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $renaming) {
                NameSheet(title: "Rename Group", initial: group?.name ?? "") { name in
                    await model.manage("updateCategoryGroup", ["id": .string(groupID), "name": .string(name)])
                }
            }
            .sheet(isPresented: $addingCategory) {
                NameSheet(title: "New Category", action: "Add") { name in
                    await model.manage("createCategory", ["groupId": .string(groupID), "name": .string(name)])
                }
            }
            .sheet(isPresented: $editingNotes) {
                NotesSheet(id: groupID, title: group?.name ?? "Notes", initial: group?.notes ?? "")
            }
            .confirmationDialog("Delete this group?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Group", role: .destructive) { Task { await delete(transferTo: nil) } }
            } message: { Text("Its categories have no transactions or budgets, so they are deleted with it.") }
            .navigationDestination(isPresented: $choosesTransfer) {
                DeleteTransferForm(
                    title: "Delete Group",
                    message: "Categories in this group have transactions or budgets. Choose a category to receive them.",
                    candidates: siblings.filter { $0.id != groupID }) { await delete(transferTo: $0) }
            }
        }
    }

    private func move(before target: String?) {
        var arguments: [String: JSONValue] = ["id": .string(groupID)]
        if let target { arguments["targetId"] = .string(target) }
        Task { await model.manage("moveCategoryGroup", arguments) }
    }

    private func startDelete() {
        Task {
            do {
                var required = false
                for category in group?.categories ?? [] {
                    if try await model.categoryNeedsTransfer(category.id) { required = true; break }
                }
                if required { choosesTransfer = true } else { confirmsDelete = true }
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    @discardableResult
    private func delete(transferTo target: String?) async -> Bool {
        var arguments: [String: JSONValue] = ["id": .string(groupID)]
        if let target { arguments["transferId"] = .string(target) }
        let deleted = await model.manage("deleteCategoryGroup", arguments)
        if deleted { dismiss() }
        return deleted
    }
}

/// A category's management form in its own sheet, for categories without a budget editor.
struct CategoryManageSheet: View {
    let categoryID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CategoryManageForm(categoryID: categoryID) { dismiss() }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Adds an account without a bank connection, as Actual's "Add local account" does.
struct NewAccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var offBudget = false
    @State private var balance = ""
    @State private var validation: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("e.g. Bank, Savings, Credit Card, Cash"))
                        .accessibilityLabel("Name")
                    Toggle("Off budget", isOn: $offBudget)
                } footer: {
                    Text(offBudget
                         ? "Off-budget accounts, such as investments or loans, count toward net worth but not your budget."
                         : "On-budget accounts hold money you budget, such as checking and cash.")
                }
                Section {
                    AmountField(label: "Starting balance", text: $balance, placeholder: Money.editable(0))
                } header: { Text("Starting balance") } footer: {
                    Text("Use a negative amount, such as −250, for a credit card or loan balance.")
                }
                if let validation { Section { Text(validation).foregroundStyle(.red) } }
                if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
            }
            .navigationTitle("New Account").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.isBusy) }
                ToolbarItem(placement: .confirmationAction) { Button("Add", action: save).bold().disabled(model.isBusy) }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { validation = "Name cannot be blank."; return }
        let cents = balance.isEmpty ? 0 : Money.parse(balance)
        guard let cents else { validation = "Enter a balance, with no more than two decimal places."; return }
        validation = nil
        Task {
            if await model.manage("createAccount", [
                "name": .string(trimmed), "offBudget": .bool(offBudget), "balance": .number(cents),
            ]) { dismiss() }
        }
    }
}

/// Closes an account as Actual's close dialog does: an account without transactions is
/// deleted; otherwise a balance moves to another account, and the account can be force closed.
struct CloseAccountSheet: View {
    let account: Account
    /// Called once the account is closed or deleted.
    var onClosed: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var transferAccount = ""
    @State private var category = ""
    @State private var validation: String?
    @State private var confirmsForce = false

    private var hasTransactions: Bool { model.transactions.contains { $0.accountId == account.id } }
    private var others: [Account] { model.overview?.openAccounts.filter { $0.id != account.id } ?? [] }
    /// From on budget to off budget, the transfer leaves the budget and needs a category.
    private var needsCategory: Bool {
        !account.offbudget && others.first { $0.id == transferAccount }?.offbudget == true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(hasTransactions
                         ? "This account has transactions, so it is closed rather than deleted. You can reopen it later."
                         : "This account has no transactions, so it will be permanently deleted.")
                }
                if account.balance != 0 {
                    Section {
                        Picker("Transfer to", selection: $transferAccount) {
                            Text("Choose an account").tag("")
                            ForEach(others) { Text($0.name).tag($0.id) }
                        }
                        if needsCategory {
                            NavigationLink {
                                CategoryPicker(selection: $category,
                                               groups: model.budget?.visibleGroups.filter { !$0.isIncome } ?? [])
                            } label: {
                                LabeledContent("Category",
                                               value: model.budget?.categories.first { $0.id == category }?.name ?? "Choose")
                            }
                        }
                    } header: {
                        Text("Balance \(Money.formatted(account.balance, currency: model.currency))")
                    } footer: {
                        Text(needsCategory
                             ? "Moving money from your budget to an off-budget account needs a category."
                             : "To close this account, move its balance to another account.")
                    }
                }
                if hasTransactions {
                    Section {
                        Button("Force Close", role: .destructive) { confirmsForce = true }
                    } footer: {
                        Text("Force closing deletes the account and all its transactions. Transfers to it lose their other side.")
                    }
                }
                if let validation { Section { Text(validation).foregroundStyle(.red) } }
                if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
            }
            .disabled(model.isBusy)
            .navigationTitle("Close Account").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Close Account", action: close).bold() }
            }
            .confirmationDialog("Delete \(account.name) and all its transactions?", isPresented: $confirmsForce,
                                titleVisibility: .visible) {
                Button("Force Close", role: .destructive) { run(["id": .string(account.id), "forced": .bool(true)]) }
            } message: { Text("This cannot be undone.") }
        }
    }

    private func close() {
        var arguments: [String: JSONValue] = ["id": .string(account.id)]
        if account.balance != 0 {
            guard !transferAccount.isEmpty else { validation = "Transfer is required."; return }
            arguments["transferAccountId"] = .string(transferAccount)
            if needsCategory {
                guard !category.isEmpty else { validation = "Category is required."; return }
                arguments["categoryId"] = .string(category)
            }
        }
        validation = nil
        run(arguments)
    }

    private func run(_ arguments: [String: JSONValue]) {
        Task {
            if await model.manage("closeAccount", arguments) {
                dismiss()
                onClosed()
            }
        }
    }
}

/// Opens the category management form from the budget editor.
struct ManageCategoryRoute: Hashable {}
