import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showConnection = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Your budget") {
                    LabeledContent("Name", value: model.snapshot?.budgetName ?? "Actual")
                    LabeledContent("Currency", value: model.currency.isEmpty ? "Budget default (no symbol)" : model.currency)
                }
                Section {
                    Label(model.syncStatus, systemImage: "icloud")
                    if let date = model.lastSyncedAt {
                        LabeledContent("Last synced") { Text(date, format: .dateTime.hour().minute()) }
                    }
                    Button { Task { await model.perform("sync") } } label: {
                        HStack { Text("Sync now"); Spacer(); if model.isBusy { ProgressView() } }
                    }.disabled(model.isBusy)
                    Button("Connect to a server") { showConnection = true }.disabled(model.isBusy)
                } header: { Text("Sync") } footer: {
                    Text("Local changes are kept on this device. Sync sends and receives updates with your Actual server.")
                }
                if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
                Section {
                    Button("Choose another budget") {
                        Task { if await model.closeBudget() { dismiss() } }
                    }.disabled(model.isBusy)
                } footer: { Text("Your saved budget stays on this device.") }
                Section {
                    Label("Actual", systemImage: "chart.pie.fill").foregroundStyle(ActualTheme.purple).font(.headline)
                    Text("Your money. Your plan.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(model.isBusy) } }
            .sheet(isPresented: $showConnection) { ConnectionView() }
            .interactiveDismissDisabled(model.isBusy)
        }
    }
}

struct ConnectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var serverURL = ""
    @State private var password = ""
    @State private var syncID = ""
    @State private var budgetPassword = ""
    @State private var connected = false
    @State private var validation: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://actual.example.com", text: $serverURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Server address")
                    SecureField("Server password", text: $password)
                    Button {
                        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                            validation = "Enter your server’s full address, including https:// or http://."
                            return
                        }
                        validation = nil
                        Task {
                            connected = await model.connect(url: url.absoluteString, password: password)
                            if connected { password = "" }
                        }
                    } label: {
                        HStack { Text(connected ? "Reconnect" : "Connect"); Spacer(); if model.isBusy { ProgressView() } }
                    }
                } header: { Text("Actual server") } footer: {
                    Text("Use the address and password you use to open Actual in your browser.")
                }.disabled(model.isBusy)
                if let validation { Section { Text(validation).foregroundStyle(.red) } }
                if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
                if connected && !model.serverBudgets.isEmpty {
                    Section("Server budgets") {
                        ForEach(model.serverBudgets) { budget in
                            Button {
                                syncID = budget.cloudFileId ?? budget.id
                            } label: {
                                HStack {
                                    Label(budget.name, systemImage: "folder")
                                    Spacer()
                                    if syncID == (budget.cloudFileId ?? budget.id) { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }.disabled(model.isBusy)
                }
                Section {
                    TextField("Budget sync ID", text: $syncID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Encryption password (if set)", text: $budgetPassword)
                    Button("Download and open budget") {
                        let identifier = syncID.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !identifier.isEmpty else { validation = "Enter or choose a budget sync ID."; return }
                        validation = nil
                        Task {
                            if await model.perform("download", arguments: ["syncId": .string(identifier), "password": .string(budgetPassword)]) { dismiss() }
                        }
                    }.disabled(syncID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: { Text("Open a budget") } footer: {
                    Text("Select a budget above, or enter its Sync ID from Actual’s Advanced settings. You can use an ID when your server cannot list budgets. The encryption password is separate from your server password.")
                }.disabled(model.isBusy)
            }
            .navigationTitle("Connect to Actual").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(model.isBusy) } }
            .interactiveDismissDisabled(model.isBusy)
        }
    }
}
