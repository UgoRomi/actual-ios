import SwiftUI

struct AccountsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        NavigationStack {
            List {
                if let error = model.errorMessage { Section { ErrorNotice(message: error) { Task { await model.refresh() } } } }
                if let snapshot = model.snapshot {
                    if snapshot.accounts.isEmpty {
                        ContentUnavailableView("No accounts yet", systemImage: "creditcard", description: Text("Add an account in Actual to see its balance and transactions here."))
                    }
                    accountSection("On budget", accounts: snapshot.accounts.filter { !$0.offbudget && !$0.closed })
                    accountSection("Off budget", accounts: snapshot.accounts.filter { $0.offbudget && !$0.closed })
                    accountSection("Closed", accounts: snapshot.accounts.filter(\.closed))
                }
                Section { SyncFooter() }.listRowBackground(Color.clear)
            }
            .navigationTitle("Accounts")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsButton() } }
            .refreshable { await model.refresh() }
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
                                Text(account.closed ? "Closed account" : "Current balance").font(.caption).foregroundStyle(.secondary)
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
