import SwiftUI

/// Asks for the bank's current balance, as Actual's reconcile modal does.
struct ReconcileSheet: View {
    let accountID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var validation: String?

    private var account: Account? { model.overview?.accounts.first { $0.id == accountID } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AmountField(label: "Bank balance", text: $amount, large: true, focusesOnAppear: true)
                } header: { Text("Bank balance") } footer: {
                    Text("Enter the current balance of your bank account that you want to reconcile with.")
                }
                if let bankBalance = account?.bankBalance {
                    Section {
                        LabeledContent("Last balance from bank") { MoneyText(value: bankBalance, currency: model.currency) }
                        Button("Use last synced total") { amount = Money.editable(bankBalance) }
                    }
                }
                Section {
                    LabeledContent("Cleared balance") { MoneyText(value: account?.clearedBalance ?? 0, currency: model.currency) }
                } footer: {
                    if let date = account?.lastReconciledDate {
                        Text("Reconciled \(date.formatted(.relative(presentation: .named))) (\(date.formatted(date: .abbreviated, time: .omitted)))")
                    } else { Text("Not yet reconciled") }
                }
                if let validation { Section { Text(validation).foregroundStyle(.red) } }
            }
            .navigationTitle("Reconcile").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Reconcile") { reconcile() }.bold() }
            }
            .onAppear {
                // Adjusting a reconciliation in progress starts from its balance.
                let current = model.reconciliation?.accountID == accountID ? model.reconciliation?.targetBalance : nil
                amount = Money.editable(current ?? account?.clearedBalance ?? 0)
            }
        }.presentationDetents([.medium, .large])
    }

    private func reconcile() {
        guard let balance = Money.parse(amount) else {
            validation = "Enter an amount or calculation, with no more than two decimal places."
            return
        }
        model.startReconciliation(accountID: accountID, targetBalance: balance)
        dismiss()
    }
}

/// Compares the cleared balance with the bank's, as Actual's reconciling banner does.
struct ReconcilingBanner: View {
    let account: Account
    let reconciliation: Reconciliation
    @Environment(AppModel.self) private var model

    var body: some View {
        let cleared = account.clearedBalance ?? 0
        let difference = reconciliation.targetBalance - cleared
        Section("Reconciling") {
            VStack(alignment: .leading, spacing: 14) {
                if difference == 0 {
                    Label("All reconciled!", systemImage: "checkmark.circle.fill")
                        .font(.headline).foregroundStyle(.green)
                    Text("Your cleared balance matches your bank’s balance of \(Text(money(reconciliation.targetBalance)).bold()).")
                        .font(.subheadline)
                    Button { Task { await model.finishReconciliation(lock: true) } } label: {
                        Text("Lock transactions").frame(maxWidth: .infinity)
                    }.buttonStyle(.glassProminent)
                } else {
                    Text("Your cleared balance \(Text(money(cleared)).bold()) needs \(Text((difference > 0 ? "+" : "") + money(difference)).bold()) to match your bank’s balance of \(Text(money(reconciliation.targetBalance)).bold()).")
                        .font(.subheadline)
                    Button { Task { await model.createReconciliationTransaction() } } label: {
                        Text("Create reconciliation transaction").frame(maxWidth: .infinity)
                    }.buttonStyle(.glass)
                    Button { Task { await model.finishReconciliation(lock: false) } } label: {
                        Text("Exit reconciliation").frame(maxWidth: .infinity)
                    }.buttonStyle(.glassProminent)
                }
            }.padding(.vertical, 6)
        }.disabled(model.isBusy)
    }

    private func money(_ value: Int) -> String { Money.formatted(value, currency: model.currency) }
}

/// Clears or unclears a transaction from its row. Reconciled transactions unlock after a warning.
struct ClearedToggle: View {
    let transaction: Transaction
    @Environment(AppModel.self) private var model
    @State private var confirmsUnlock = false

    var body: some View {
        Button {
            if transaction.isReconciled { confirmsUnlock = true }
            else {
                let cleared = !transaction.cleared
                Task {
                    await model.edit("setCleared", arguments: ["id": .string(transaction.id), "cleared": .bool(cleared)],
                                     showing: .setCleared(id: transaction.id, cleared: cleared))
                }
            }
        } label: {
            Image(systemName: transaction.isReconciled ? "lock.fill" : transaction.cleared ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(transaction.isReconciled || transaction.cleared ? ActualTheme.purple : Color.secondary)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(model.isBusy)
        .accessibilityLabel(transaction.isReconciled ? "Unlock reconciled transaction"
                            : transaction.cleared ? "Mark uncleared" : "Mark cleared")
        .confirmationDialog("Unlock this transaction?", isPresented: $confirmsUnlock, titleVisibility: .visible) {
            Button("Unlock transaction") {
                Task {
                    await model.edit("unlockTransaction", arguments: ["id": .string(transaction.id)],
                                     showing: .unlock(id: transaction.id))
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Unlocking this transaction means you won’t be warned about changes that can affect your reconciled balance, such as its amount, account, or payee.")
        }
    }
}
