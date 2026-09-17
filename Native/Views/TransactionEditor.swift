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

    var body: some View {
        NavigationStack {
            Form {
                if !editable {
                    Section {
                        Label("View only", systemImage: "lock")
                        Text("Edit transfers and split transactions in the Actual web or desktop app to preserve their linked entries.")
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
                        ForEach(model.snapshot?.accounts.filter { !$0.closed || $0.id == account } ?? []) { item in
                            Text(item.name).tag(item.id)
                        }
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    HStack {
                        TextField("Payee", text: $payee).textInputAutocapitalization(.words)
                        if !(model.snapshot?.payees.isEmpty ?? true) {
                            Menu("Choose payee", systemImage: "person.crop.circle") {
                                ForEach(model.snapshot?.payees ?? []) { item in
                                    Button(item.name) { payee = item.name }
                                }
                            }.labelStyle(.iconOnly)
                        }
                    }
                    Picker("Category", selection: $category) {
                        Text("Uncategorized").tag("")
                        ForEach(model.snapshot?.groups ?? []) { group in
                            Section(group.name) {
                                ForEach(group.categories) { item in Text(item.name).tag(item.id) }
                            }
                        }
                    }
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
                    Label("Changes are saved on this device. Sync with your server from Settings.", systemImage: "internaldrive")
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
        account = accountID ?? model.snapshot?.openAccounts.first?.id ?? ""
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
        if let match = model.snapshot?.payees.first(where: { $0.name == cleanedPayee }) {
            arguments["payeeId"] = .string(match.id)
        } else if !cleanedPayee.isEmpty { arguments["payeeName"] = .string(cleanedPayee) }
        else { arguments["payeeId"] = .null }
        let commandArguments = arguments
        Task { if await model.perform("saveTransaction", arguments: commandArguments) { dismiss() } }
    }
}
