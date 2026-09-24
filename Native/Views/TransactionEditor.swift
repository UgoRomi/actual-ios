import SwiftUI

struct TransactionEditor: View {
    var transaction: Transaction? = nil
    var accountID: String? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var isOutflow = true
    @State private var date = Date()
    @State private var account = ""
    @State private var payee = ""
    @State private var category = ""
    @State private var notes = ""
    @State private var cleared = false
    @State private var validation: String?
    @State private var showDeleteConfirmation = false
    @State private var initialized = false

    private var editable: Bool { transaction?.canEdit ?? true }
    /// Actual never categorizes off-budget transactions.
    private var isOffBudget: Bool { model.overview?.accounts.first { $0.id == account }?.offbudget == true }
    private var categoryName: String {
        if isOffBudget { return "Off budget" }
        if category.isEmpty { return "Uncategorized" }
        // Hidden categories are not listed, but a transaction can still use one.
        return model.budget?.categories.first { $0.id == category }?.name
            ?? (transaction?.categoryId == category ? transaction?.categoryName : nil) ?? "Uncategorized"
    }

    var body: some View {
        NavigationStack {
            Form {
                if !editable {
                    Section {
                        Label("View only", systemImage: "lock")
                        Text("Edit transfers, split transactions, and reconciled transactions in the Actual web or desktop app.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Picker("Type", selection: $isOutflow) {
                        Text("Payment").tag(true)
                        Text("Deposit").tag(false)
                    }.pickerStyle(.segmented)
                    HStack(alignment: .firstTextBaseline) {
                        Text(isOutflow ? "−" : "+").foregroundStyle(.secondary)
                        TextField("0.00", text: $amount)
                            .keyboardType(.decimalPad)
                            .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                            .monospacedDigit().accessibilityLabel("Amount")
                        if !model.currency.isEmpty { Text(model.currency).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 8)
                }.disabled(!editable || model.isBusy)
                Section("Details") {
                    Picker("Account", selection: $account) {
                        Text("Choose an account").tag("")
                        ForEach(model.overview?.accounts.filter { !$0.closed || $0.id == account } ?? []) { item in
                            Text(item.name).tag(item.id)
                        }
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    NavigationLink {
                        PayeePicker(selection: $payee, payees: model.overview?.payees ?? [])
                    } label: {
                        LabeledContent("Payee", value: payee.isEmpty ? "None" : payee)
                    }.accessibilityIdentifier("payee-row")
                    NavigationLink {
                        CategoryPicker(selection: $category, groups: model.budget?.groups ?? [])
                    } label: {
                        LabeledContent("Category", value: categoryName)
                    }.disabled(isOffBudget).accessibilityIdentifier("category-row")
                    Toggle("Cleared", isOn: $cleared)
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...5)
                }.disabled(!editable || model.isBusy)
                if let validation { Section { Text(validation).foregroundStyle(.red) } }
                if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
                if transaction != nil && editable {
                    Section {
                        Button("Delete transaction", role: .destructive) { showDeleteConfirmation = true }
                            .disabled(model.isBusy)
                    }
                }
                Section {
                    Label(model.canSyncBudget
                          ? "Changes are saved on this device, then synced automatically with your server."
                          : "Changes are saved on this device.", systemImage: "internaldrive")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(transaction == nil ? "New transaction" : "Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(editable ? "Cancel" : "Done") { dismiss() }.disabled(model.isBusy) }
                if editable {
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.bold().disabled(model.isBusy) }
                }
            }
            .interactiveDismissDisabled(model.isBusy)
            .confirmationDialog("Delete this transaction?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete transaction", role: .destructive) {
                    if let transaction {
                        Task { if await model.perform("deleteTransaction", arguments: ["id": .string(transaction.id)]) { dismiss() } }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: { Text("This removes the transaction from your budget and updates your balances.") }
            .onAppear { initialize() }
        }
    }

    private func initialize() {
        guard !initialized else { return }
        initialized = true
        account = transaction?.accountId ?? accountID ?? model.overview?.openAccounts.first?.id ?? ""
        guard let transaction else { return }
        amount = Money.editable(abs(transaction.amount))
        isOutflow = transaction.amount < 0
        date = BudgetDate.date(transaction.date) ?? Date()
        payee = transaction.payeeId == nil ? "" : (transaction.payeeName ?? "")
        category = transaction.categoryId ?? ""
        notes = transaction.notes ?? ""
        cleared = transaction.cleared
    }

    private func save() {
        guard !account.isEmpty else { validation = "Choose an account before saving."; return }
        guard let parsed = Money.parse(amount), parsed >= 0 else { validation = "Enter a positive amount with no more than two decimal places."; return }
        validation = nil
        var arguments: [String: JSONValue] = [
            "accountId": .string(account), "date": .string(BudgetDate.day(date)),
            "amount": .number(isOutflow ? -parsed : parsed), "notes": .string(notes), "cleared": .bool(cleared),
            "categoryId": category.isEmpty ? .null : .string(category)
        ]
        if let transaction { arguments["id"] = .string(transaction.id) }
        let cleanedPayee = payee.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = model.overview?.payees.first(where: { $0.name == cleanedPayee }) {
            arguments["payeeId"] = .string(match.id)
        } else if !cleanedPayee.isEmpty { arguments["payeeName"] = .string(cleanedPayee) }
        else { arguments["payeeId"] = .null }
        let commandArguments = arguments
        Task { if await model.perform("saveTransaction", arguments: commandArguments) { dismiss() } }
    }
}

/// Search existing payees, or add a new one by name.
struct PayeePicker: View {
    @Binding var selection: String
    let payees: [Payee]
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matches: [Payee] {
        query.isEmpty ? payees : payees.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    /// Actual reuses a payee whose name differs only in case, so do not offer to add one.
    private var canAdd: Bool {
        !query.isEmpty && !payees.contains { $0.name.compare(query, options: .caseInsensitive) == .orderedSame }
    }

    var body: some View {
        List {
            if canAdd {
                Section {
                    Button { choose(query) } label: { Label("Add “\(query)”", systemImage: "plus.circle") }
                }
            }
            Section {
                if query.isEmpty { choice("No payee", value: "") }
                ForEach(matches) { payee in choice(payee.name, value: payee.name) }
            }
        }
        .navigationTitle("Payee").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search or add a payee")
        .searchFocused($searchFocused)
        .onAppear { searchFocused = true }
    }

    private func choice(_ title: String, value: String) -> some View {
        Button { choose(value) } label: {
            HStack {
                Text(title).foregroundStyle(Color.primary)
                Spacer()
                if selection == value { Image(systemName: "checkmark").foregroundStyle(ActualTheme.purple) }
            }
        }
    }

    private func choose(_ value: String) {
        selection = value
        dismiss()
    }
}

/// Search categories by their own or their group's name.
struct CategoryPicker: View {
    @Binding var selection: String
    let groups: [CategoryGroup]
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matches: [CategoryGroup] {
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let categories = group.name.localizedCaseInsensitiveContains(query)
                ? group.categories : group.categories.filter { $0.name.localizedCaseInsensitiveContains(query) }
            return categories.isEmpty ? nil : CategoryGroup(id: group.id, name: group.name, categories: categories)
        }
    }

    var body: some View {
        List {
            if query.isEmpty { Section { choice("Uncategorized", id: "") } }
            ForEach(matches) { group in
                Section(group.name) {
                    ForEach(group.categories) { category in choice(category.name, id: category.id) }
                }
            }
        }
        .overlay { if matches.isEmpty && !query.isEmpty { ContentUnavailableView.search(text: query) } }
        .navigationTitle("Category").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search categories")
    }

    private func choice(_ title: String, id: String) -> some View {
        Button {
            selection = id
            dismiss()
        } label: {
            HStack {
                Text(title).foregroundStyle(Color.primary)
                Spacer()
                if selection == id { Image(systemName: "checkmark").foregroundStyle(ActualTheme.purple) }
            }
        }
    }
}
