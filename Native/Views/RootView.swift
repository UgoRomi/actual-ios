import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Group {
            if !model.hasStarted {
                ActualTheme.background.ignoresSafeArea()
            } else if model.isBudgetOpen {
                TabView {
                    Tab("Budget", systemImage: "chart.pie") { BudgetView() }
                    Tab("Accounts", systemImage: "creditcard") { AccountsView() }
                    Tab("Transactions", systemImage: "list.bullet.rectangle") { TransactionsView() }
                    Tab("Schedules", systemImage: "calendar.badge.clock") { SchedulesView() }
                    Tab("Reports", systemImage: "chart.bar.xaxis") { ReportsView() }
                }
            } else { WelcomeView() }
        }
        // Date pickers start the week on the budget's first day, as Actual's do.
        .environment(\.calendar, model.overview.map { _ in BudgetDate.calendar } ?? .autoupdatingCurrent)
        .disabled(model.isOpeningBudget)
        .overlay {
            if !model.hasStarted || model.isOpeningBudget { openingBudget }
        }
    }

    private var openingBudget: some View {
        VStack(spacing: 18) {
            Image(systemName: "chart.pie.fill").font(.system(size: 44)).foregroundStyle(ActualTheme.purple)
            ProgressView(model.isSyncingBudget ? "Syncing your budget…" : "Opening your budget…")
            if model.isAwaitingOpeningSync {
                VStack(spacing: 8) {
                    Button("Continue offline") { model.continueOffline() }.buttonStyle(.glass)
                    Text("Use the budget saved on this device. Syncing continues in the background.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(.top, 12)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(ActualTheme.background)
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showConnection = false
    @State private var budgetToDelete: BudgetFile?
    @State private var isDeleting = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 20) {
                        Image(systemName: "chart.pie.fill")
                            .font(.system(size: 48)).foregroundStyle(.white)
                            .padding(22).background(ActualTheme.purple, in: RoundedRectangle(cornerRadius: 28))
                            .accessibilityHidden(true)
                        Text("Actual").font(.largeTitle.bold())
                        Text("Make room for what matters.")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        Text("A little clarity for your everyday money. Your budget stays with you, even when you’re offline.")
                            .font(.title3).foregroundStyle(.secondary)
                    }.padding(.top, 40)
                    if let error = model.errorMessage {
                        ErrorNotice(message: error) {
                            model.hasStarted = false
                            Task { await model.start() }
                        }
                    }
                    if !model.localBudgets.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("ON THIS DEVICE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(model.localBudgets) { budget in
                                Button { Task { await model.openBudget(budget.id) } } label: {
                                    HStack { Label(budget.name, systemImage: "folder"); Spacer(); Image(systemName: "chevron.right") }
                                        .padding().background(ActualTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                                }.buttonStyle(.plain)
                                .contextMenu {
                                    Button("Delete from This Device", systemImage: "trash", role: .destructive) {
                                        budgetToDelete = budget
                                    }
                                }
                                .confirmationDialog(
                                    "Delete “\(budget.name)” from this device?",
                                    isPresented: Binding(
                                        get: { budgetToDelete?.id == budget.id },
                                        set: { if !$0 { budgetToDelete = nil } }),
                                    titleVisibility: .visible
                                ) {
                                    Button("Delete from This Device", role: .destructive) { delete(budget) }
                                    Button("Cancel", role: .cancel) { }
                                } message: {
                                    Text(budget.cloudFileId == nil
                                         ? "This budget is not on a server. Deleting it removes it permanently."
                                         : "Your server keeps this budget, so you can download it again. Changes not yet synced to your server are lost.")
                                }
                            }
                            Text("Touch and hold a budget to delete it from this device.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    VStack(spacing: 14) {
                        Button { showConnection = true } label: {
                            Text("Connect to your server").frame(maxWidth: .infinity).padding(.vertical, 8)
                        }.buttonStyle(.glassProminent)
                        Button { Task { await model.perform("demo") } } label: {
                            Text("Explore a demo budget").frame(maxWidth: .infinity).padding(.vertical, 8)
                        }.buttonStyle(.glass)
                        Text("The demo is a separate budget with sample data.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }.padding(24).frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
            }
            .background(ActualTheme.background)
            .disabled(model.isBusy)
            .overlay(alignment: .bottom) {
                if model.isBusy {
                    ProgressView(isDeleting ? "Deleting budget…" : "Opening budget…").padding().glassEffect().padding()
                }
            }
            .sheet(isPresented: $showConnection) { ConnectionView() }
        }
    }

    private func delete(_ budget: BudgetFile) {
        isDeleting = true
        Task {
            await model.deleteBudget(budget.id)
            isDeleting = false
        }
    }
}

struct SettingsButton: View {
    @State private var isPresented = false
    var body: some View {
        Button("Settings", systemImage: "gearshape") { isPresented = true }
            .sheet(isPresented: $isPresented) { SettingsView() }
    }
}

struct SyncFooter: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsWarning = false
    var body: some View {
        VStack(spacing: 12) {
            if let warning = model.overview?.syncWarning {
                ErrorNotice(message: warning.message)
                if warning.kind == .dropped {
                    Button("Keep using this budget") { confirmsWarning = true }
                        .buttonStyle(.bordered).disabled(model.isBusy)
                        .confirmationDialog("Keep using this budget?", isPresented: $confirmsWarning, titleVisibility: .visible) {
                            Button("Keep using this budget") { Task { await model.acknowledgeSyncWarning() } }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("Actual continues after this warning too. Values changed on the other device may stay different here until someone edits them again. Your edits here sync to all devices.")
                        }
                }
            }
            if let error = model.syncErrorMessage {
                ErrorNotice(message: error) { Task { await model.perform("sync") } }
            }
            Label(model.syncStatus, systemImage: model.syncStatus == "Sync needs attention" ? "exclamationmark.icloud" : "internaldrive")
                .font(.footnote).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 12)
    }
}
