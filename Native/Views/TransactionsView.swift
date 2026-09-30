import SwiftUI
import UniformTypeIdentifiers

struct TransactionsView: View {
    var accountID: String? = nil
    var accountName: String? = nil
    var embedsNavigation = true
    /// Only transactions whose notes have this #tag, as Actual's tag filter shows them.
    var tag: String? = nil
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var shownCount = TransactionSection.pageSize
    @State private var selectedTransaction: Transaction?
    @State private var isAdding = false
    @State private var showsReconcile = false
    @State private var renaming = false
    @State private var editingNotes = false
    @State private var closing = false
    @State private var choosingFile = false
    @State private var importing: ImportFile?
    @State private var fileError: String?
    @State private var selectedScheduled: ScheduledTransaction?
    @Environment(\.dismiss) private var dismiss

    private var account: Account? { accountID.flatMap { id in model.overview?.accounts.first { $0.id == id } } }
    private var reconciliation: Reconciliation? {
        model.reconciliation.flatMap { $0.accountID == accountID ? $0 : nil }
    }

    var body: some View {
        if embedsNavigation { NavigationStack { content } }
        else { content }
    }

    private var content: some View {
        let listed = tag.map { tag in model.transactions.filter { transaction in
            ([transaction.notes ?? ""] + (transaction.splits ?? []).map(\.notes)).contains { NoteTags.extract($0).contains(tag) }
        } } ?? model.transactions
        let sections = TransactionSection.grouped(listed, accountID: accountID, search: search,
                                                  currency: model.currency, limit: shownCount)
        let hasMore = sections.reduce(0) { $0 + $1.transactions.count } == shownCount
        return ThemedList {
            if let error = model.errorMessage { Section { ErrorNotice(message: error) { Task { await model.refresh() } } } }
            if let accountID { BankSyncNotice(accountID: accountID) }
            if let account, let reconciliation { ReconcilingBanner(account: account, reconciliation: reconciliation) }
            let upcoming = model.upcoming.filter { scheduled in
                tag == nil && (accountID == nil || scheduled.accountId == accountID)
                    && (search.isEmpty || scheduled.title.localizedCaseInsensitiveContains(search)
                        || (scheduled.categoryName ?? "").localizedCaseInsensitiveContains(search))
            }
            if !upcoming.isEmpty {
                Section("Upcoming") {
                    ForEach(upcoming) { scheduled in
                        Button { selectedScheduled = scheduled } label: {
                            ScheduledTransactionRow(scheduled: scheduled, currency: model.currency)
                        }.buttonStyle(.plain).disabled(model.isBusy)
                    }
                }
            }
            if sections.isEmpty && upcoming.isEmpty {
                ContentUnavailableView(search.isEmpty ? "A fresh start" : "No matching transactions", systemImage: search.isEmpty ? "list.bullet.rectangle" : "magnifyingglass", description: Text(search.isEmpty ? "Your transactions will appear here. Add one to keep your budget up to date." : "Try a different payee, category, or amount."))
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section.transactions) { transaction in
                        HStack(spacing: 4) {
                            Button { selectedTransaction = transaction } label: {
                                TransactionRow(transaction: transaction, currency: model.currency)
                            }.buttonStyle(.plain)
                            ClearedToggle(transaction: transaction)
                        }
                    }
                } header: {
                    if let parsed = BudgetDate.date(section.date) { Text(parsed, format: .dateTime.weekday(.wide).month(.abbreviated).day()) }
                    else { Text(section.date) }
                }
            }
            if hasMore {
                // Shows the next page once the end of the list scrolls into view.
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                    .onAppear { shownCount += TransactionSection.pageSize }
            }
            Section { SyncFooter() }.listRowBackground(Color.clear)
        }
        .onChange(of: search) { shownCount = TransactionSection.pageSize }
        .navigationTitle(accountName ?? "Transactions")
        .searchable(text: $search, prompt: "Payee, category, or amount")
        .toolbar {
            if accountID != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reconcile", systemImage: "checkmark.seal") { showsReconcile = true }
                        .disabled(model.isBusy || account == nil || account?.closed == true)
                }
                ToolbarItem(placement: .topBarTrailing) { accountMenu }
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
        // Actual's scheduled transaction menu.
        .confirmationDialog(selectedScheduled?.title ?? "", isPresented: $selectedScheduled.isPresent,
                            titleVisibility: .visible, presenting: selectedScheduled) { scheduled in
            let id: [String: JSONValue] = ["id": .string(scheduled.scheduleId)]
            Button("Post Transaction") { Task { await model.manage("postSchedule", id) } }
            Button("Post Transaction Today") {
                Task { await model.manage("postSchedule", id.merging(["today": .bool(true)]) { $1 }) }
            }
            if scheduled.recurring {
                Button("Skip Next Scheduled Date") { Task { await model.manage("skipSchedule", id) } }
            } else {
                Button("Mark as Completed") {
                    Task { await model.manage("completeSchedule", id.merging(["completed": .bool(true)]) { $1 }) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { scheduled in
            if let date = BudgetDate.date(scheduled.date) {
                Text("Scheduled for \(date.formatted(.dateTime.month(.wide).day().year()))")
            }
        }
        // As Actual's import dialog: OFX/QFX, QIF, CSV/TSV, or CAMT XML from Files.
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: UTType.importable) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { importing = ImportFile(name: url.lastPathComponent, data: try Data(contentsOf: url)) }
                catch { fileError = "The file could not be opened. \(error.localizedDescription)" }
            case .failure(let error): fileError = error.localizedDescription
            }
        }
        .sheet(item: $importing) { file in
            if let accountID { ImportSheet(accountID: accountID, fileName: file.name, data: file.data) }
        }
        .alert("Import", isPresented: $fileError.isPresent) {
            Button("OK") {}
        } message: { Text(fileError ?? "") }
        .sheet(isPresented: $renaming) {
            if let account {
                NameSheet(title: "Rename Account", initial: account.name) { name in
                    await model.manage("updateAccount", ["id": .string(account.id), "name": .string(name)])
                }
            }
        }
        .sheet(isPresented: $editingNotes) {
            if let account { NotesSheet(id: "account-\(account.id)", title: account.name, initial: account.notes ?? "") }
        }
        .sheet(isPresented: $closing) {
            // A closed account without transactions is deleted; leave its page.
            if let account { CloseAccountSheet(account: account) { if self.account == nil { dismiss() } } }
        }
    }

    /// Actual's mobile account menu.
    private var accountMenu: some View {
        Menu("Account options", systemImage: "ellipsis.circle") {
            Button("Rename Account", systemImage: "pencil") { renaming = true }
            Button("Account Notes", systemImage: "note.text") { editingNotes = true }
            if account?.closed != true {
                Button("Import Transactions", systemImage: "square.and.arrow.down") { choosingFile = true }
            }
            if account?.closed == true {
                Button("Reopen Account", systemImage: "arrow.uturn.backward") {
                    if let accountID { Task { await model.manage("reopenAccount", ["id": .string(accountID)]) } }
                }
            } else {
                Button("Close Account", systemImage: "archivebox", role: .destructive) { closing = true }
            }
        }
        .disabled(model.isBusy || account == nil)
    }
}

/// An upcoming scheduled transaction, with its date and status, as Actual's register shows it.
struct ScheduledTransactionRow: View {
    let scheduled: ScheduledTransaction
    let currency: String
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(scheduled.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                HStack(spacing: 6) {
                    ScheduleStatusBadge(status: scheduled.shownStatus)
                    Text(BudgetDate.display(scheduled.date))
                    if let category = scheduled.categoryName { Text("· \(category)") }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            // Actual's register shows previews in light text.
            MoneyText(value: scheduled.amount, currency: currency, positiveColor: ActualTheme.positive, negativeColor: .secondary)
                .font(.body.weight(.semibold))
        }.padding(.vertical, 6).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityHint("Post or skip this scheduled transaction")
    }
}

struct TransactionRow: View {
    let transaction: Transaction
    let currency: String
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(transaction.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                // As in Actual's mobile register, transfers and splits are marked beside the category.
                // The title and detail already say so to VoiceOver.
                HStack(spacing: 4) {
                    if transaction.isTransfer { Image(systemName: "arrow.left.arrow.right").accessibilityHidden(true) }
                    else if transaction.isParent { Image(systemName: "square.split.2x2").accessibilityHidden(true) }
                    Text(transaction.canEdit ? transaction.detail : "\(transaction.detail) · view only")
                }.font(.caption).foregroundStyle(.secondary)
                if let notes = transaction.notes, !notes.isEmpty { NotesText(notes: notes).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            MoneyText.transaction(transaction.amount, currency: currency).font(.body.weight(.semibold))
        }.padding(.vertical, 6).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }
}

/// A file chosen for import.
struct ImportFile: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
}
