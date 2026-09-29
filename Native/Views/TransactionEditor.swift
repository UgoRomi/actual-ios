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
    /// Another account, for a transfer. As in Actual, it takes the payee's place.
    @State private var transferAccount = ""
    @State private var category = ""
    @State private var notes = ""
    @State private var cleared = false
    @State private var validation: String?
    @State private var showDeleteConfirmation = false
    @State private var confirmsReconciledSave = false
    @State private var initialized = false
    /// A split's parts, in the transaction's direction. Empty for an ordinary transaction.
    @State private var splits: [SplitDraft] = []

    private var editable: Bool { transaction?.canEdit ?? true }
    /// The latest load: this transaction, or a transfer's linked transaction,
    /// may have been reconciled since the editor opened.
    private var current: Transaction? {
        transaction.map { transaction in model.transactions.first { $0.id == transaction.id } ?? transaction }
    }
    private var isReconciled: Bool { current?.isReconciled == true }
    private var isTransferReconciled: Bool { current?.transferReconciled == true }
    private var accounts: [Account] { model.overview?.accounts ?? [] }
    private var transferTarget: Account? { transferAccount.isEmpty ? nil : accounts.first { $0.id == transferAccount } }
    /// Open accounts other than this one, and the current choice. Like Actual's
    /// payee list, on-budget accounts come first.
    private var transferAccounts: [Account] {
        let offered = accounts.filter { $0.id != account && (!$0.closed || $0.id == transferAccount) }
        return offered.filter { !$0.offbudget } + offered.filter(\.offbudget)
    }
    /// Actual never categorizes off-budget transactions.
    private var isOffBudget: Bool { accounts.first { $0.id == account }?.offbudget == true }
    /// Nor transfers to an on-budget account: from on-budget, the budget is unchanged.
    private var isBudgetTransfer: Bool { transferTarget.map { !$0.offbudget } ?? false }
    private var payeeLabel: String {
        if !transferAccount.isEmpty {
            return "Transfer \(isOutflow ? "to" : "from") \(transferTarget?.name ?? "a deleted account")"
        }
        return payee.isEmpty ? "None" : payee
    }
    private var categoryName: String {
        if isOffBudget { return "Off budget" }
        if isBudgetTransfer { return "Transfer" }
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
                        Text(transaction?.transferInSplit == true
                             ? "This transfer is linked to part of a split transaction. Edit it in the Actual web or desktop app."
                             : "This split includes a transfer. Edit it in the Actual web or desktop app.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else if isReconciled {
                    Section {
                        Label("Reconciled", systemImage: "lock")
                        Text("Changing this transaction may bring your reconciliation out of balance. To change whether it’s cleared, unlock it while reconciling the account.")
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
                        // A new transaction starts with its amount, as in Actual.
                        AmountField(label: "Amount", text: $amount, large: true, focusesOnAppear: transaction == nil,
                                    textColor: isOutflow ? .label : .systemGreen)
                        if !model.currency.isEmpty { Text(model.currency).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 8)
                }.disabled(!editable || model.isBusy)
                Section {
                    Picker("Account", selection: $account) {
                        Text("Choose an account").tag("")
                        ForEach(model.overview?.accounts.filter { !$0.closed || $0.id == account } ?? []) { item in
                            Text(item.name).tag(item.id)
                        }
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        // Rebuilding the picker closes its calendar once a date is chosen.
                        .id(date)
                    NavigationLink {
                        PayeePicker(selection: $payee, transferAccount: $transferAccount,
                                    payees: model.overview?.payees ?? [], accounts: transferAccounts)
                    } label: {
                        LabeledContent("Payee", value: payeeLabel)
                    }.accessibilityIdentifier("payee-row")
                    if splits.isEmpty {
                        NavigationLink {
                            CategoryPicker(selection: $category, groups: model.budget?.visibleGroups ?? [])
                        } label: {
                            LabeledContent("Category", value: categoryName)
                        }.disabled(isOffBudget || isBudgetTransfer).accessibilityIdentifier("category-row")
                    }
                    if isReconciled { Toggle("Reconciled", isOn: .constant(true)).disabled(true) }
                    else { Toggle("Cleared", isOn: $cleared) }
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...5)
                } header: { Text("Details") } footer: { if editable { transferFooter } }
                .disabled(!editable || model.isBusy)
                splitSection.disabled(!editable || model.isBusy)
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
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { if isReconciled || isTransferReconciled { confirmsReconciledSave = true } else { save() } }
                            .bold().disabled(model.isBusy)
                    }
                }
            }
            .interactiveDismissDisabled(model.isBusy)
            .confirmationDialog("Delete this transaction?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete transaction", role: .destructive) {
                    if let transaction {
                        let arguments: [String: JSONValue] = [
                            "id": .string(transaction.id), "allowReconciled": .bool(isReconciled),
                            "allowReconciledTransfer": .bool(isTransferReconciled),
                        ]
                        // As in Actual's mobile app, close right away; a failure shows in the register.
                        Task { await model.edit("deleteTransaction", arguments: arguments, showing: .delete(id: transaction.id)) }
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: { Text(deleteMessage) }
            // As in Actual's mobile editor, any save of a reconciled transaction,
            // or of a transfer whose linked transaction is reconciled, warns first.
            .confirmationDialog(isReconciled ? "Save this reconciled transaction?" : "Save this transfer?",
                                isPresented: $confirmsReconciledSave, titleVisibility: .visible) {
                Button("Save changes") { save(confirmed: true) }
                Button("Cancel", role: .cancel) { }
            } message: { Text(saveMessage) }
            .onAppear { initialize() }
        }
    }

    /// The total less the parts, in the transaction's direction; nil when an amount is invalid.
    private var amountLeft: Int? {
        guard let total = Money.parse(amount) else { return nil }
        var left = total
        for part in splits {
            guard let value = part.amount.isEmpty ? 0 : Money.parse(part.amount) else { return nil }
            left -= value
        }
        return left
    }

    /// Actual's split editing: each part has its own amount, category, and notes.
    @ViewBuilder private var splitSection: some View {
        if splits.isEmpty {
            if transferAccount.isEmpty {
                Section {
                    Button("Split Transaction", systemImage: "square.split.2x2") { split() }
                } footer: { Text("Divide this amount between categories.") }
            }
        } else {
            ForEach($splits) { $part in
                Section {
                    AmountField(label: "Split amount", text: $part.amount)
                    NavigationLink {
                        CategoryPicker(selection: $part.category, groups: model.budget?.visibleGroups ?? [])
                    } label: {
                        LabeledContent("Category", value: isOffBudget ? "Off budget" : name(ofCategory: part.category))
                    }.disabled(isOffBudget)
                    TextField("Notes", text: $part.notes, axis: .vertical).lineLimit(1...3)
                    Button("Delete Split", systemImage: "trash", role: .destructive) {
                        splits.removeAll { $0.id == part.id }
                    }
                } header: {
                    Text("Split \((splits.firstIndex { $0.id == part.id } ?? 0) + 1)")
                }
            }
            Section {
                Button("Add Split", systemImage: "plus") {
                    // As in Actual, a new part starts with what is left.
                    let left = max(amountLeft ?? 0, 0)
                    splits.append(SplitDraft(amount: left == 0 ? "" : Money.editable(left)))
                }
            } footer: {
                if let left = amountLeft, left != 0 {
                    Text("Amount left: \(Money.formatted(left, currency: model.currency))").foregroundStyle(.orange)
                } else if amountLeft == nil {
                    Text("Enter each amount with no more than two decimal places.").foregroundStyle(.red)
                } else {
                    Text("The parts add up to the total.")
                }
            }
        }
    }

    private func name(ofCategory id: String) -> String {
        guard !id.isEmpty else { return "Uncategorized" }
        return model.budget?.categories.first { $0.id == id }?.name
            ?? transaction?.splits?.first { $0.categoryId == id }?.categoryName ?? "Uncategorized"
    }

    /// Like Actual's Split: the first part keeps the amount and category, and a second starts empty.
    private func split() {
        splits = [SplitDraft(amount: amount, category: isOffBudget || isBudgetTransfer ? "" : category), SplitDraft()]
    }

    /// What saving does in the other account, as Actual's transfer handling does.
    @ViewBuilder private var transferFooter: some View {
        if let transferTarget {
            Text(current?.transferId == nil
                 ? "Saving also adds the matching transaction to \(transferTarget.name)."
                 : "Its linked transaction in \(transferTarget.name) gets the same amount and notes, but keeps its own date and cleared state.")
        } else if current?.transferId != nil, let previous = accounts.first(where: { $0.id == current?.transferAccountId }) {
            Text("Choosing a payee removes the linked transaction from \(previous.name).")
        }
    }

    /// Actual's confirmations, naming each reconciliation that may fall out of balance.
    private var saveMessage: String {
        switch (isReconciled, isTransferReconciled) {
        case (true, true): "This transaction and its linked transaction in another account are reconciled. Saving your changes may bring their reconciliations out of balance."
        case (true, false): "Saving your changes to this reconciled transaction may bring your reconciliation out of balance."
        default: "This transfer has a linked transaction in another account that is reconciled. Editing it may bring that account’s reconciliation out of balance."
        }
    }

    private var deleteMessage: String {
        switch (isReconciled, isTransferReconciled) {
        case (true, true): "This transaction and its linked transaction in another account are reconciled. Deleting them may bring their reconciliations out of balance."
        case (true, false): "Deleting reconciled transactions may bring your reconciliation out of balance."
        case (false, true): "This transfer has a linked transaction in another account that is reconciled. Deleting it may bring that account’s reconciliation out of balance."
        case (false, false): current?.transferId == nil
            ? "This removes the transaction from your budget and updates your balances."
            : "This removes the transfer from both accounts and updates your balances."
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
        // A transfer's payee stands for the other account, not a name to reuse.
        transferAccount = transaction.transferAccountId ?? ""
        payee = transaction.payeeId == nil || !transferAccount.isEmpty ? "" : (transaction.payeeName ?? "")
        category = transaction.categoryId ?? ""
        notes = transaction.notes ?? ""
        cleared = transaction.cleared
        splits = (transaction.splits ?? []).map(SplitDraft.init)
    }

    /// A confirmation covers whatever is reconciled now, as its message describes.
    private func save(confirmed: Bool = false) {
        guard !account.isEmpty else { validation = "Choose an account before saving."; return }
        guard transferAccount != account else { validation = "Choose two different accounts for a transfer."; return }
        guard let parsed = Money.parse(amount), parsed >= 0 else { validation = "Enter a positive amount or calculation, with no more than two decimal places."; return }
        validation = nil
        var arguments: [String: JSONValue] = [
            "accountId": .string(account), "date": .string(BudgetDate.day(date)),
            "amount": .number(isOutflow ? -parsed : parsed), "notes": .string(notes), "cleared": .bool(cleared),
            "categoryId": category.isEmpty || isOffBudget || isBudgetTransfer ? .null : .string(category)
        ]
        if let transaction {
            arguments["id"] = .string(transaction.id)
            arguments["allowReconciled"] = .bool(confirmed && isReconciled)
            arguments["allowReconciledTransfer"] = .bool(confirmed && isTransferReconciled)
        }
        // Actual's IDs are lowercase UUIDs.
        let id = transaction?.id ?? UUID().uuidString.lowercased()
        if transaction == nil { arguments["newId"] = .string(id) }
        let cleanedPayee = payee.trimmingCharacters(in: .whitespacesAndNewlines)
        let match = model.overview?.payees.first { $0.name == cleanedPayee }
        if !transferAccount.isEmpty {
            arguments["transferAccountId"] = .string(transferAccount)
        } else if let match {
            arguments["payeeId"] = .string(match.id)
        } else if !cleanedPayee.isEmpty { arguments["payeeName"] = .string(cleanedPayee) }
        else { arguments["payeeId"] = .null }
        var shown = preview(id: id, amount: isOutflow ? -parsed : parsed, payeeID: match?.id, payeeName: cleanedPayee)
        var method = "saveTransaction"
        // A split, or a split whose parts were all removed, saves with its parts.
        let parts = splits.filter { !$0.isEmpty }
        if !parts.isEmpty || transaction?.isParent == true {
            guard transferAccount.isEmpty else { validation = "A split can’t be a transfer. Choose a payee."; return }
            var saved: [SplitPart] = []
            for part in parts {
                guard let cents = part.amount.isEmpty ? 0 : Money.parse(part.amount), cents >= 0 else {
                    validation = "Enter each split amount as a positive number, with no more than two decimal places."
                    return
                }
                let categoryID = part.category.isEmpty || isOffBudget ? nil : part.category
                saved.append(SplitPart(id: part.savedID ?? part.id, amount: isOutflow ? -cents : cents,
                                       categoryId: categoryID, categoryName: categoryID.map(name(ofCategory:)),
                                       notes: part.notes, isTransfer: false))
            }
            let left = parsed - saved.reduce(0) { $0 + abs($1.amount) }
            // As in Actual, a split saves only once its parts add up to the total.
            guard parts.isEmpty || left == 0 else {
                validation = "The split amounts must add up to the total. Amount left: \(Money.formatted(left, currency: model.currency))."
                return
            }
            method = "saveSplit"
            arguments["splits"] = .array(zip(parts, saved).map { draft, part in
                var fields: [String: JSONValue] = [
                    "amount": .number(part.amount), "notes": .string(part.notes),
                    "categoryId": part.categoryId.map { .string($0) } ?? .null,
                ]
                if let savedID = draft.savedID { fields["id"] = .string(savedID) }
                return .object(fields)
            })
            if !parts.isEmpty {
                shown.isParent = true
                shown.splits = saved
                shown.categoryId = nil
                shown.categoryName = nil
            }
        }
        let commandArguments = arguments
        // As in Actual's mobile app, close right away; a failure shows in the register.
        let previewed = shown, command = method
        Task { await model.edit(command, arguments: commandArguments, showing: .save(previewed)) }
        dismiss()
    }

    /// The saved transaction as the register will show it, until the engine reloads it.
    /// Rules may still change a new transaction's payee or category.
    private func preview(id: String, amount: Int, payeeID: String?, payeeName: String) -> Transaction {
        let existing = current
        let sameTransfer = !transferAccount.isEmpty && existing?.transferAccountId == transferAccount
        let categoryID = category.isEmpty || isOffBudget || isBudgetTransfer ? nil : category
        // As in the engine, a reconciled transaction stays cleared, and moving it unlocks it.
        let reconciled = existing?.isReconciled == true && existing?.accountId == account
        return Transaction(
            id: id, accountId: account, date: BudgetDate.day(date),
            payeeId: transferAccount.isEmpty ? payeeID : sameTransfer ? existing?.payeeId : nil,
            payeeName: transferAccount.isEmpty ? (payeeName.isEmpty ? nil : payeeName) : transferTarget?.name,
            categoryId: categoryID, categoryName: categoryID == nil ? "Uncategorized" : categoryName,
            amount: amount, notes: notes, cleared: existing?.isReconciled == true ? existing?.cleared ?? cleared : cleared,
            isParent: false, isChild: false, isTransfer: !transferAccount.isEmpty, reconciled: reconciled,
            transferAccountId: transferAccount.isEmpty ? nil : transferAccount,
            transferId: sameTransfer ? existing?.transferId : nil,
            transferReconciled: sameTransfer ? existing?.transferReconciled : nil)
    }
}

/// A split part being edited. Existing parts keep their ID, so saving updates them.
struct SplitDraft: Identifiable {
    let id: String
    /// Set for a part already saved.
    let savedID: String?
    var amount: String
    var category: String
    var notes: String

    init(amount: String = "", category: String = "", notes: String = "") {
        id = UUID().uuidString
        savedID = nil
        self.amount = amount
        self.category = category
        self.notes = notes
    }

    init(_ part: SplitPart) {
        id = part.id
        savedID = part.id
        amount = Money.editable(abs(part.amount))
        category = part.categoryId ?? ""
        notes = part.notes
    }

    /// A part with nothing entered, which saving leaves out.
    var isEmpty: Bool { (Money.parse(amount) ?? 0) == 0 && category.isEmpty && notes.isEmpty }
}

/// Search existing payees, add a new one by name, or choose another account for a transfer.
struct PayeePicker: View {
    @Binding var selection: String
    @Binding var transferAccount: String
    let payees: [Payee]
    /// Accounts to transfer with.
    let accounts: [Account]
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matches: [Payee] {
        query.isEmpty ? payees : payees.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var matchingAccounts: [Account] {
        query.isEmpty ? accounts : accounts.filter { $0.name.localizedCaseInsensitiveContains(query) }
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
            if query.isEmpty { Section { choice("No payee", value: "") } }
            // Before payees: the account list is short, and payees can number in the hundreds.
            if !matchingAccounts.isEmpty {
                Section("Transfer to/from") {
                    ForEach(matchingAccounts) { account in
                        Button {
                            transferAccount = account.id
                            selection = ""
                            dismiss()
                        } label: {
                            row(account.name, detail: account.offbudget ? "Off budget" : nil,
                                selected: transferAccount == account.id)
                        }
                        .accessibilityLabel("Transfer to or from \(account.name)")
                        .accessibilityValue(account.offbudget ? "Off budget" : "")
                    }
                }
            }
            if !matches.isEmpty {
                Section("Payees") { ForEach(matches) { payee in choice(payee.name, value: payee.name) } }
            }
        }
        .navigationTitle("Payee").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search or add a payee")
        .searchFocused($searchFocused)
        .onAppear { searchFocused = true }
    }

    private func choice(_ title: String, value: String) -> some View {
        Button { choose(value) } label: { row(title, selected: transferAccount.isEmpty && selection == value) }
    }

    private func row(_ title: String, detail: String? = nil, selected: Bool) -> some View {
        HStack {
            Text(title).foregroundStyle(Color.primary)
            Spacer()
            if let detail { Text(detail).font(.caption).foregroundStyle(Color.secondary) }
            if selected { Image(systemName: "checkmark").foregroundStyle(ActualTheme.purple) }
        }
    }

    private func choose(_ value: String) {
        selection = value
        transferAccount = ""
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
