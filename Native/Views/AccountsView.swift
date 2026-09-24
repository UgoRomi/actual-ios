import SwiftUI

struct AccountsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        NavigationStack {
            List {
                if let error = model.errorMessage { Section { ErrorNotice(message: error) { Task { await model.refresh() } } } }
                BankSyncNotice()
                if let overview = model.overview {
                    if overview.accounts.isEmpty {
                        ContentUnavailableView("No accounts yet", systemImage: "creditcard", description: Text("Add an account in Actual to see its balance and transactions here."))
                    }
                    accountSection("On budget", accounts: overview.accounts.filter { !$0.offbudget && !$0.closed })
                    accountSection("Off budget", accounts: overview.accounts.filter { $0.offbudget && !$0.closed })
                    accountSection("Closed", accounts: overview.accounts.filter(\.closed))
                }
                Section { SyncFooter() }.listRowBackground(Color.clear)
            }
            .navigationTitle("Accounts")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsButton() } }
            .refreshable { await model.refreshAccounts() }
        }
    }

    @ViewBuilder private func accountSection(_ title: String, accounts: [Account]) -> some View {
        if !accounts.isEmpty {
            Section(title) {
                ForEach(accounts) { account in
                    NavigationLink {
                        TransactionsView(accountID: account.id, accountName: account.name, embedsNavigation: false)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: account.closed ? "archivebox" : "creditcard")
                                .font(.title3).foregroundStyle(ActualTheme.purple)
                                .frame(width: 44, height: 44)
                                .background(ActualTheme.purple.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(account.name).font(.body.weight(.medium))
                                if model.syncingAccountIDs.contains(account.id) {
                                    HStack { ProgressView().controlSize(.mini); Text("Refreshing bank…") }
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if account.canSyncBank {
                                    if account.bankSyncNeedsAttention {
                                        Label("Bank connection needs attention", systemImage: "exclamationmark.circle")
                                            .font(.caption).foregroundStyle(.orange)
                                    } else if let date = account.lastBankSyncDate {
                                        Text("Bank refreshed \(date, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text("Bank connected · pull to refresh").font(.caption).foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text(account.closed ? "Closed account" : "Current balance").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            MoneyText(value: account.balance, currency: model.currency).font(.headline)
                        }.padding(.vertical, 6)
                    }
                }
            }
        }
    }
}

struct BankSyncNotice: View {
    @Environment(AppModel.self) private var model
    var accountID: String? = nil

    private var applies: Bool { accountID == nil || model.bankSyncAccountID == nil || model.bankSyncAccountID == accountID }
    private var results: [BankSyncAccountResult] {
        model.bankSyncResult?.accounts.filter { accountID == nil || $0.accountId == accountID } ?? []
    }

    var body: some View {
        if applies {
            if !model.syncingAccountIDs.isEmpty && (accountID == nil || model.syncingAccountIDs.contains(accountID ?? "")) {
                Section { ProgressView("Refreshing bank accounts…") }
            } else if let error = model.bankSyncErrorMessage {
                Section { ErrorNotice(message: error) { Task { await model.refreshAccounts(accountID: accountID ?? model.bankSyncAccountID) } } }
            } else if !results.isEmpty {
                Section("Bank refresh") {
                    let succeeded = results.filter { $0.error == nil }.count
                    if succeeded > 0 {
                        Label(succeeded == 1 ? "1 account refreshed" : "\(succeeded) accounts refreshed", systemImage: "checkmark.circle")
                            .font(.subheadline)
                    }
                    ForEach(results.filter { $0.error != nil }) { result in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.overview?.accounts.first { $0.id == result.accountId }?.name ?? "Account").font(.headline)
                            Text(result.error ?? "Bank refresh failed.").font(.subheadline).foregroundStyle(.secondary)
                            Button("Try again") { Task { await model.refreshAccounts(accountID: result.accountId) } }
                                .disabled(model.isBusy)
                        }
                    }
                }
            }
        }
    }
}
