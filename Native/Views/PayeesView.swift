import SwiftUI

/// Actual's payees page: rename, merge, and delete payees, and clear out unused ones.
struct PayeesView: View {
    @Environment(AppModel.self) private var model
    @State private var payees: [ManagedPayee] = []
    @State private var loadError: String?
    @State private var search = ""
    @State private var showsUnusedOnly = false
    @State private var confirmsDeleteUnused = false

    private var shown: [ManagedPayee] {
        payees.filter { payee in
            (!showsUnusedOnly || payee.unused) && (search.isEmpty || payee.name.localizedCaseInsensitiveContains(search))
        }
    }
    private var unused: [ManagedPayee] { payees.filter(\.unused) }

    var body: some View {
        List {
            if let error = model.errorMessage ?? loadError { Section { ErrorNotice(message: error) } }
            if !unused.isEmpty {
                Section {
                    Toggle("Show only unused payees", isOn: $showsUnusedOnly)
                    Button("Delete \(unused.count) Unused \(unused.count == 1 ? "Payee" : "Payees")", role: .destructive) {
                        confirmsDeleteUnused = true
                    }.disabled(model.isBusy)
                } footer: { Text("Unused payees have no transactions.") }
            }
            Section {
                ForEach(shown) { payee in
                    NavigationLink {
                        PayeeDetail(payeeID: payee.id, payees: $payees) { await load() }
                    } label: {
                        HStack {
                            Text(payee.name)
                            Spacer()
                            if payee.unused { Text("Unused").font(.caption).foregroundStyle(.secondary) }
                            if payee.ruleCount > 0 {
                                Text(payee.ruleCount == 1 ? "1 rule" : "\(payee.ruleCount) rules")
                                    .font(.caption).foregroundStyle(ActualTheme.purple)
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if shown.isEmpty && loadError == nil {
                ContentUnavailableView(search.isEmpty ? "No payees" : "No matching payees", systemImage: "person.2")
            }
        }
        .navigationTitle("Payees")
        .searchable(text: $search, prompt: "Search payees")
        .task(id: model.dataRevision) { await load() }
        .confirmationDialog("Delete \(unused.count) unused \(unused.count == 1 ? "payee" : "payees")?",
                            isPresented: $confirmsDeleteUnused, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    if await model.manage("deletePayees", ["ids": .array(unused.map { .string($0.id) })]) { await load() }
                }
            }
        } message: { Text("Rules that use them may stop matching.") }
    }

    private func load() async {
        do { payees = try await model.managedPayees(); loadError = nil }
        catch { loadError = error.localizedDescription }
    }
}

/// One payee: rename, merge into another payee, or delete.
private struct PayeeDetail: View {
    let payeeID: String
    @Binding var payees: [ManagedPayee]
    var reload: () async -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var merging = false
    @State private var confirmsDelete = false

    private var payee: ManagedPayee? { payees.first { $0.id == payeeID } }

    var body: some View {
        Form {
            if let payee {
                Section {
                    Button { renaming = true } label: { LabeledContent("Name", value: payee.name) }
                    LabeledContent("Rules", value: "\(payee.ruleCount)")
                    LabeledContent("Transactions", value: payee.unused ? "None" : "Yes")
                }
                Section {
                    Button("Merge into Another Payee", systemImage: "arrow.triangle.merge") { merging = true }
                } footer: {
                    Text("Merging moves this payee’s transactions and rules to the payee you choose, then removes this one.")
                }
                Section {
                    Button("Delete Payee", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                } footer: {
                    Text(payee.unused ? "No transactions use this payee." : "Its transactions will have no payee.")
                }
            }
            if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
        }
        .disabled(model.isBusy)
        .navigationTitle(payee?.name ?? "Payee").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $renaming) {
            NameSheet(title: "Rename Payee", initial: payee?.name ?? "") { name in
                let renamed = await model.manage("renamePayee", ["id": .string(payeeID), "name": .string(name)])
                if renamed { await reload() }
                return renamed
            }
        }
        .sheet(isPresented: $merging) {
            MergeTargetPicker(payees: payees.filter { $0.id != payeeID }) { target in
                let merged = await model.manage("mergePayees", [
                    "targetId": .string(target.id), "mergeIds": .array([.string(payeeID)]),
                ])
                if merged { await reload(); dismiss() }
                return merged
            }
        }
        .confirmationDialog("Delete \(payee?.name ?? "this payee")?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Payee", role: .destructive) {
                Task {
                    if await model.manage("deletePayees", ["ids": .array([.string(payeeID)])]) { await reload(); dismiss() }
                }
            }
        }
    }
}

/// Chooses the payee to keep when merging.
private struct MergeTargetPicker: View {
    let payees: [ManagedPayee]
    let merge: (ManagedPayee) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List(payees.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { payee in
                Button(payee.name) { Task { if await merge(payee) { dismiss() } } }
                    .foregroundStyle(Color.primary).disabled(model.isBusy)
            }
            .navigationTitle("Merge Into").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search payees")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
