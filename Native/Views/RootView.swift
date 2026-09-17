import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Group {
            if model.snapshot != nil {
                TabView {
                    Tab("Budget", systemImage: "chart.pie") { BudgetView() }
                    Tab("Accounts", systemImage: "creditcard") { AccountsView() }
                    Tab("Transactions", systemImage: "list.bullet.rectangle") { TransactionsView() }
                }
            } else if !model.hasStarted {
                VStack(spacing: 18) {
                    Image(systemName: "chart.pie.fill").font(.system(size: 44)).foregroundStyle(ActualTheme.purple)
                    ProgressView("Opening your budget…")
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(ActualTheme.background)
            } else { WelcomeView() }
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showConnection = false
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
                            }
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
            .overlay(alignment: .bottom) { if model.isBusy { ProgressView("Opening budget…").padding().glassEffect().padding() } }
            .sheet(isPresented: $showConnection) { ConnectionView() }
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
    var body: some View {
        Label(model.syncStatus, systemImage: model.syncStatus == "Sync needs attention" ? "exclamationmark.icloud" : "internaldrive")
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
    }
}
