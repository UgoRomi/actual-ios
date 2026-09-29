import AuthenticationServices
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showConnection = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Your budget") {
                    LabeledContent("Name", value: model.overview?.budgetName ?? "Actual")
                    LabeledContent("Currency", value: model.currency.isEmpty ? "Budget default (no symbol)" : model.currency)
                }
                Section {
                    Label(model.syncStatus, systemImage: "icloud")
                    if let date = model.lastSyncedAt {
                        LabeledContent("Last synced") { Text(date, format: .dateTime.hour().minute()) }
                    }
                    Button { Task { await model.perform("sync") } } label: {
                        HStack { Text("Sync now"); Spacer(); if model.isSyncingBudget { ProgressView() } }
                    }.disabled(model.isBusy || model.isSyncingBudget || !model.canSyncBudget)
                    Button("Connect to a server") { showConnection = true }.disabled(model.isBusy)
                } header: { Text("Sync") } footer: {
                    Text(model.canSyncBudget
                         ? "Your budget syncs when you open the app and after changes. Edits are saved on this device first. Sync now retries immediately."
                         : "This budget is saved only on this device. Open a budget from your server to sync it.")
                }
                if let error = model.syncErrorMessage { Section { ErrorNotice(message: error) } }
                if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
                if model.isBudgetOpen {
                    Section("Manage") {
                        NavigationLink { PayeesView() } label: { Label("Payees", systemImage: "person.2") }
                        NavigationLink { RulesView() } label: { Label("Rules", systemImage: "wand.and.rays") }
                        NavigationLink { TagsView() } label: { Label("Tags", systemImage: "number") }
                    }
                    formatting
                }
                Section {
                    Button("Choose another budget") {
                        Task { if await model.closeBudget() { dismiss() } }
                    }.disabled(model.isBusy)
                } footer: { Text("Your saved budget stays on this device. You can delete it from the budget list.") }
                Section {
                    Label("Actual", systemImage: "chart.pie.fill").foregroundStyle(ActualTheme.purple).font(.headline)
                    Text("Unofficial client for Actual Budget.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .disabled(model.isBusy)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(model.isBusy) } }
            .sheet(isPresented: $showConnection) { ConnectionView() }
            .interactiveDismissDisabled(model.isBusy)
        }
    }
}

extension SettingsView {
    /// Actual's formatting settings. They belong to the budget, so every device shows them alike.
    @ViewBuilder var formatting: some View {
        let format = model.overview?.format
        Section {
            Picker("Numbers", selection: preference("numberFormat", format?.numberFormat ?? "")) {
                if format?.numberFormat == nil { Text("This device’s").tag("") }
                ForEach(BudgetFormat.numberFormats, id: \.value) { Text($0.label).tag($0.value) }
            }
            Toggle("Hide decimal places", isOn: Binding(
                get: { format?.hideFraction ?? false },
                set: { save("hideFraction", $0 ? "true" : "false") }))
            Picker("Dates", selection: preference("dateFormat", format?.dateFormat ?? "")) {
                if format?.dateFormat == nil { Text("This device’s").tag("") }
                ForEach(BudgetFormat.dateFormats, id: \.self) { Text($0.uppercased()).tag($0) }
            }
            Picker("First day of the week", selection: preference(
                "firstDayOfWeekIdx", format?.firstDayOfWeekIdx.map(String.init) ?? "")) {
                if format?.firstDayOfWeekIdx == nil { Text("This device’s").tag("") }
                ForEach(0..<7, id: \.self) { Text(Calendar(identifier: .gregorian).weekdaySymbols[$0]).tag(String($0)) }
            }
        } header: { Text("Formatting") } footer: {
            Text("These settings belong to the budget, so Actual web and desktop use them too.")
        }
    }

    private func preference(_ id: String, _ current: String) -> Binding<String> {
        Binding(get: { current }, set: { save(id, $0) })
    }

    private func save(_ id: String, _ value: String) {
        guard !value.isEmpty else { return }
        Task { await model.manage("savePreference", ["id": .string(id), "value": .string(value)]) }
    }
}

struct ConnectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var serverURL = ""
    @State private var password = ""
    /// How the server at `serverURL` lets people sign in, once checked.
    @State private var options: LoginOptions?
    @State private var signingIn: LoginMethod?
    @State private var syncID = ""
    @State private var budgetPassword = ""
    @State private var connected = false
    @State private var validation: String?

    /// Before anyone signs in with OpenID, Actual confirms the server password.
    private var needsOwnerPassword: Bool {
        guard let options else { return false }
        return !options.ownerCreated && options.methods.contains(.openid) && options.methods.contains(.password)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://actual.example.com", text: $serverURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Server address")
                        .onSubmit { if options == nil { checkServer() } }
                        .onChange(of: serverURL) { options = nil }
                    if let options {
                        if options.methods.contains(.password) {
                            SecureField("Server password", text: $password)
                        }
                        ForEach(options.methods, id: \.self) { method in
                            Button { signIn(method) } label: {
                                HStack { Text(method.title); Spacer(); if signingIn == method { ProgressView() } }
                            }.disabled(method == .openid && needsOwnerPassword && password.isEmpty)
                        }
                    } else {
                        Button(action: checkServer) {
                            HStack { Text("Continue"); Spacer(); if model.isBusy { ProgressView() } }
                        }
                    }
                } header: { Text("Actual server") } footer: {
                    Text(serverFooter)
                }.disabled(model.isBusy)
                if let validation { Section { Text(validation).foregroundStyle(.red) } }
                if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
                if connected && !model.serverBudgets.isEmpty {
                    Section("Server budgets") {
                        ForEach(model.serverBudgets) { budget in
                            Button {
                                syncID = budget.id
                            } label: {
                                HStack {
                                    Label(budget.name, systemImage: "folder")
                                    Spacer()
                                    if syncID == budget.id { Image(systemName: "checkmark") }
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

    private var serverFooter: String {
        guard let options else { return "Enter the address you use to open Actual in your browser." }
        guard options.methods.contains(.openid), !options.ownerCreated else {
            return "Sign in as you do in Actual in your browser."
        }
        let owner = "The first person to sign in with OpenID becomes the server owner. This can’t be changed later."
        return needsOwnerPassword ? owner + " Enter the server password to confirm." : owner
    }

    /// The entered address, or nil after explaining what is wrong with it.
    private func validatedURL() -> String? {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            validation = "Enter your server’s full address, including https:// or http://."
            return nil
        }
        validation = nil
        return url.absoluteString
    }

    private func checkServer() {
        guard let url = validatedURL() else { return }
        Task { options = await model.loginOptions(url: url) }
    }

    private func signIn(_ method: LoginMethod) {
        guard let url = validatedURL() else { return }
        signingIn = method
        Task {
            let succeeded = switch method {
            case .password: await model.connect(url: url, password: password)
            case .openid: await model.connectWithOpenID(url: url, password: password, authenticate: authenticate)
            }
            if succeeded {
                connected = true
                password = ""
                // An OpenID sign-in leaves the server with an owner.
                if method == .openid, let current = options {
                    options = LoginOptions(methods: current.methods, ownerCreated: true)
                }
            }
            signingIn = nil
        }
    }

    /// Shows the provider in the system's browser sheet, which supports passkeys
    /// and existing Safari sign-ins. Returns nil if the person cancels.
    private func authenticate(_ url: URL) async throws -> URL? {
        do {
            return try await webAuthenticationSession.authenticate(
                using: url, callback: .customScheme(OpenIDCallback.scheme),
                preferredBrowserSession: nil, additionalHeaderFields: [:])
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return nil
        }
    }
}

private extension LoginMethod {
    var title: String { self == .openid ? "Sign in with OpenID" : "Sign in with password" }
}
