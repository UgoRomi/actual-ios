import SwiftUI

struct TransactionsView: View {
    var accountID: String? = nil
    var accountName: String? = nil
    var embedsNavigation = true
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selectedTransaction: Transaction?
    @State private var isAdding = false
    @State private var showsReconcile = false

    private var account: Account? { accountID.flatMap { id in model.overview?.accounts.first { $0.id == id } } }
    private var reconciliation: Reconciliation? {
        model.reconciliation.flatMap { $0.accountID == accountID ? $0 : nil }
    }

    var body: some View {
        if embedsNavigation { NavigationStack { content } }
        else { content }
    }

    private var content: some View {
        let sections = TransactionSection.grouped(model.transactions, accountID: accountID,
                                                  search: search, currency: model.currency)
        return List {
            if let error = model.errorMessage { Section { ErrorNotice(message: error) { Task { await model.refresh() } } } }
            if let accountID { BankSyncNotice(accountID: accountID) }
            if let account, let reconciliation { ReconcilingBanner(account: account, reconciliation: reconciliation) }
            if sections.isEmpty {
                ContentUnavailableView(search.isEmpty ? "A fresh start" : "No matching transactions", systemImage: search.isEmpty ? "list.bullet.rectangle" : "magnifyingglass", description: Text(search.isEmpty ? "Your transactions will appear here. Add one to keep your budget up to date." : "Try a different payee, category, or amount."))
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section.transactions) { transaction in
                        HStack(spacing: 4) {
                            Button { selectedTransaction = transaction } label: {
                                TransactionRow(transaction: transaction, currency: model.currency,
                                               showsStatus: reconciliation == nil)
                            }.buttonStyle(.plain)
                            if reconciliation != nil { ClearedToggle(transaction: transaction) }
                        }
                    }
                } header: {
                    if let parsed = BudgetDate.date(section.date) { Text(parsed, format: .dateTime.weekday(.wide).month(.abbreviated).day()) }
                    else { Text(section.date) }
                }
            }
            Section { SyncFooter() }.listRowBackground(Color.clear)
        }
        .navigationTitle(accountName ?? "Transactions")
        .searchable(text: $search, prompt: "Payee, category, or amount")
        .toolbar {
            if accountID != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reconcile", systemImage: "checkmark.seal") { showsReconcile = true }
                        .disabled(model.isBusy || account == nil)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add transaction", systemImage: "plus") { isAdding = true }
                    .disabled(model.isBusy || model.overview?.openAccounts.isEmpty != false)
            }
        }
        .refreshable {
            if let accountID { await model.refreshAccounts(accountID: accountID) }
            else { await model.refresh() }
        }
        .sheet(isPresented: $isAdding) { TransactionEditor(accountID: accountID) }
        .sheet(isPresented: $showsReconcile) { if let accountID { ReconcileSheet(accountID: accountID) } }
        .sheet(item: $selectedTransaction) { transaction in TransactionEditor(transaction: transaction, accountID: transaction.accountId) }
    }
}

struct TransactionRow: View {
    let transaction: Transaction
    let currency: String
    /// While reconciling, a separate toggle shows the cleared state.
    var showsStatus = true
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: transaction.isTransfer ? "arrow.left.arrow.right" : transaction.isParent ? "square.split.2x2" : transaction.amount < 0 ? "arrow.up.right" : "arrow.down.left")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(transaction.amount < 0 ? Color.secondary : ActualTheme.purple)
                .frame(width: 36, height: 36)
                .background(ActualTheme.background, in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(transaction.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(transaction.isParent ? "Split transaction · view only"
                     : transaction.canEdit ? transaction.detail : "\(transaction.detail) · view only")
                    .font(.caption).foregroundStyle(.secondary)
                if let notes = transaction.notes, !notes.isEmpty { Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                MoneyText(value: transaction.amount, currency: currency).font(.body.weight(.semibold))
                if showsStatus {
                    Group {
                        if transaction.isReconciled { Text("\(Image(systemName: "lock.fill")) Reconciled") }
                        else { Text(transaction.cleared ? "Cleared" : "Uncleared") }
                    }.font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 6).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }
}
