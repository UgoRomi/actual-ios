import SwiftUI

struct BudgetView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedCategory: BudgetCategory?
    @State private var confirmOverwrite = false
    @State private var pendingMonthAction: BudgetAction?
    @State private var showsSummary = false
    @State private var route: BudgetRoute?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(model.overview?.budgetName ?? "Actual")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    monthControl
                    if let error = model.errorMessage { ErrorNotice(message: error) { Task { await model.refresh() } } }
                    if let budget = model.budget {
                        if budget.budgetType == .envelope {
                            Button { showsSummary = true } label: { summary(budget) }
                                .buttonStyle(.plain).disabled(model.isBusy)
                                .accessibilityHint("Show how To Budget adds up, and move money")
                        } else { summary(budget) }
                        BudgetBanners(budget: budget) { route = $0 }
                        if budget.groups.isEmpty {
                            ContentUnavailableView("No categories yet", systemImage: "tray", description: Text("Set up categories in Actual to start planning your money."))
                        }
                        ForEach(budget.groups.filter { $0.categories.contains { !$0.isIncome } }) { group in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(group.name).font(.title3.bold()).padding(.horizontal, 4)
                                VStack(spacing: 0) {
                                    ForEach(group.categories.filter { !$0.isIncome }) { category in
                                        Button { selectedCategory = category } label: {
                                            categoryRow(category)
                                        }.buttonStyle(.plain).disabled(model.isBusy)
                                        if category.id != group.categories.last(where: { !$0.isIncome })?.id { Divider().padding(.leading, 18) }
                                    }
                                }.background(ActualTheme.surface, in: RoundedRectangle(cornerRadius: 22))
                            }
                        }
                        SyncFooter()
                    }
                }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .background(ActualTheme.background)
            .navigationTitle("Budget")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { monthMenu }
                ToolbarItem(placement: .topBarTrailing) { SettingsButton() }
            }
            .refreshable { await model.refresh() }
            .sheet(item: $selectedCategory) { category in BudgetEditor(category: category, month: model.month) }
            .sheet(isPresented: $showsSummary) { EnvelopeSummarySheet(month: model.month, monthDate: model.selectedMonth) }
            .sheet(item: $route) { route in BudgetRouteSheet(route: route, month: model.month) }
            .confirmationDialog(pendingMonthAction.map(Self.confirmationTitle) ?? "", isPresented: Binding(
                get: { pendingMonthAction != nil }, set: { if !$0 { pendingMonthAction = nil } }
            ), titleVisibility: .visible, presenting: pendingMonthAction) { action in
                Button(Self.actionTitle(action), role: .destructive) {
                    Task { await model.budgetAction(action, month: model.month) }
                }
            } message: { _ in
                Text("This replaces what every category has budgeted for \(model.selectedMonth.formatted(.dateTime.month(.wide).year())).")
            }
            .confirmationDialog("Overwrite this month’s budget with targets?", isPresented: $confirmOverwrite, titleVisibility: .visible) {
                Button("Overwrite with Targets", role: .destructive) { Task { await model.applyTargets(month: model.month, overwrite: true) } }
            } message: {
                Text("Every category with targets gets the amount they ask for, replacing what is budgeted now.")
            }
            .alert("Targets", isPresented: Binding(get: { model.targetsMessage != nil }, set: { if !$0 { model.targetsMessage = nil } })) {
                Button("OK") {}
            } message: {
                Text(model.targetsMessage ?? "")
            }
        }
    }

    /// Actual's budget month menu: set every category's budget, then targets.
    private var monthMenu: some View {
        Menu("Month actions", systemImage: "ellipsis.circle") {
            Section {
                ForEach([BudgetAction.copyLastMonth, .setZero, .setAverage(months: 3), .setAverage(months: 6),
                         .setAverage(months: 12)], id: \.name) { action in
                    Button(Self.actionTitle(action), systemImage: Self.actionImage(action)) { pendingMonthAction = action }
                }
            }
            Section("Targets") { targetsItems }
        }
        .disabled(model.isBusy || model.budget == nil)
    }

    static func actionTitle(_ action: BudgetAction) -> String {
        switch action {
        case .copyLastMonth: "Copy Last Month’s Budget"
        case .setZero: "Set Budgets to Zero"
        case .setAverage(12): "Set Budgets to Yearly Average"
        case .setAverage(let months): "Set Budgets to \(months)-Month Average"
        default: action.name
        }
    }

    private static func actionImage(_ action: BudgetAction) -> String {
        switch action {
        case .copyLastMonth: "doc.on.doc"
        case .setZero: "0.circle"
        default: "chart.line.flattrend.xyaxis"
        }
    }

    private static func confirmationTitle(_ action: BudgetAction) -> String {
        switch action {
        case .copyLastMonth: "Copy last month’s budget?"
        case .setZero: "Set every budget to zero?"
        default: "\(actionTitle(action))?"
        }
    }

    /// Actual's budget month menu actions for targets.
    @ViewBuilder private var targetsItems: some View {
            Button {
                Task { await model.applyTargets(month: model.month) }
            } label: {
                Label("Apply Targets", systemImage: "wand.and.stars")
                Text("Budget categories that have nothing budgeted yet")
            }
            Button(role: .destructive) { confirmOverwrite = true } label: {
                Label("Overwrite with Targets", systemImage: "arrow.clockwise")
                Text("Replace what every category with targets has budgeted")
            }
    }

    private var monthControl: some View {
        HStack {
            Button("Previous month", systemImage: "chevron.left") { Task { await model.moveMonth(-1) } }
                .labelStyle(.iconOnly).buttonStyle(.glass).controlSize(.large)
            Spacer()
            Text(model.selectedMonth, format: .dateTime.month(.wide).year()).font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("Next month", systemImage: "chevron.right") { Task { await model.moveMonth(1) } }
                .labelStyle(.iconOnly).buttonStyle(.glass).controlSize(.large)
        }.disabled(model.isBusy)
    }

    private func summary(_ budget: BudgetMonth) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            let headline = SummaryHeadline(budget)
            VStack(alignment: .leading, spacing: 8) {
                Label(headline.title, systemImage: headline.systemImage)
                    .font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                Text(Money.formatted(headline.amount, currency: model.currency))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold)).monospacedDigit()
                    .foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                Text(headline.message)
                    .font(.subheadline).foregroundStyle(.white.opacity(0.8))
            }
            Divider().overlay(.white.opacity(0.2))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) {
                    summaryValue("Budgeted", budget.totalBudgeted)
                    Spacer(minLength: 24)
                    summaryValue("Spent", budget.totalSpent)
                }
                VStack(alignment: .leading, spacing: 16) {
                    summaryValue("Budgeted", budget.totalBudgeted)
                    summaryValue("Spent", budget.totalSpent)
                }
            }
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .background(ActualTheme.navy.gradient, in: RoundedRectangle(cornerRadius: 28))
    }

    private func summaryValue(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.7))
            Text(Money.formatted(value, currency: model.currency)).font(.headline).monospacedDigit().foregroundStyle(.white)
        }
    }

    private func categoryRow(_ category: BudgetCategory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(category.name).font(.body.weight(.medium))
                if category.hasTargets {
                    Image(systemName: "target").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Has targets")
                }
                Spacer(minLength: 12)
                Text(Money.formatted(category.balance, currency: model.currency))
                    .monospacedDigit().font(.headline).foregroundStyle(TargetStatus(category).balanceColor)
            }
            HStack {
                Text("Budgeted \(Money.formatted(category.budgeted, currency: model.currency))")
                Spacer(minLength: 8)
                let status = TargetStatus(category)
                Text(status.label(currency: model.currency)).foregroundStyle(status.labelColor)
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(18).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityHint("Edit budgeted amount")
    }
}

/// A category's funding against its goal, colored like Actual's balance:
/// overspent in red, then underfunded in orange and funded in green when targets set a goal.
struct TargetStatus {
    let category: BudgetCategory
    init(_ category: BudgetCategory) { self.category = category }

    var isUnderfunded: Bool { (category.goalDifference ?? 0) < 0 }
    var balanceColor: Color {
        if category.balance < 0 { return .red }
        guard category.goal != nil else { return .primary }
        return isUnderfunded ? .orange : .green
    }
    var labelColor: Color { category.balance >= 0 && isUnderfunded ? .orange : .secondary }

    func label(currency: String) -> String {
        if category.balance < 0 { return "Overspent" }
        guard let difference = category.goalDifference else { return "Available" }
        if difference == 0 { return "Fully funded" }
        let amount = Money.formatted(abs(difference), currency: currency)
        return difference > 0 ? "Overfunded (\(amount))" : "Underfunded (\(amount))"
    }
}

/// Envelope budgets lead with money left to budget; tracking budgets with savings, as in Actual's mobile web app.
private struct SummaryHeadline {
    let title: String
    let systemImage: String
    let amount: Int
    let message: String

    init(_ budget: BudgetMonth) {
        switch budget.budgetType {
        case .envelope:
            amount = budget.toBudget ?? 0
            title = amount < 0 ? "Over budget" : "Available to budget"
            systemImage = amount < 0 ? "exclamationmark.circle" : "circle.dotted"
            message = amount == 0 ? "Every bit has a purpose." : amount < 0 ? "Adjust your plan to bring it back into balance." : "Give your money a purpose, one category at a time."
        case .tracking:
            amount = budget.saved ?? 0
            systemImage = amount < 0 ? "exclamationmark.circle" : "banknote"
            if budget.savedIsProjected {
                title = "Projected savings"
                message = amount < 0 ? "Budgeted expenses exceed budgeted income." : "Budgeted income left after budgeted expenses."
            } else {
                title = amount < 0 ? "Overspent" : "Saved"
                message = amount < 0 ? "Spending exceeded income this month." : "Income left after spending this month."
            }
        }
    }
}

struct BudgetEditor: View {
    let category: BudgetCategory
    let month: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var validation: String?
    @State private var path = NavigationPath()
    @State private var detent = PresentationDetent.medium
    @State private var didAppear = false

    /// Applies a budget menu action and closes, as Actual's category menu does.
    private func run(_ action: BudgetAction) {
        Task { if await model.budgetAction(action, month: month) { dismiss() } }
    }

    /// The category as last loaded, so saved targets show here.
    private var current: BudgetCategory { model.budget?.categories.first { $0.id == category.id } ?? category }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    AmountField(label: "Budgeted amount", text: $amount, placeholder: "Budgeted amount", focusesOnAppear: true)
                } header: { Text("Budgeted for \(month)") } footer: { Text("Set the total amount you want to budget for this category.") }
                Section {
                    LabeledContent("Spent") { MoneyText(value: category.spent, currency: model.currency) }
                    LabeledContent("Available") { MoneyText(value: category.balance, currency: model.currency) }
                }
                Section {
                    if let goal = current.goal {
                        LabeledContent(current.longGoal ? "Long-term goal" : "Target this month") {
                            MoneyText(value: goal, currency: model.currency)
                        }
                        let status = TargetStatus(current)
                        LabeledContent("Status") {
                            Text(status.label(currency: model.currency)).foregroundStyle(status.labelColor)
                        }
                    }
                    NavigationLink(value: TargetsRoute()) {
                        Label(current.hasTargets ? "Edit Targets" : "Add Targets", systemImage: "target")
                    }
                    if current.hasTargets {
                        Button("Apply Target", systemImage: "wand.and.stars") {
                            Task { if await model.applyTargets(month: month, categoryID: category.id) { dismiss() } }
                        }.disabled(model.isBusy)
                    }
                } header: {
                    Text("Targets")
                } footer: {
                    if current.hasTargets { Text("Applying replaces the budgeted amount with what the targets ask for this month.") }
                }
                Section("Budget actions") {
                    Button("Copy Last Month’s Budget", systemImage: "doc.on.doc") {
                        run(.copyLastMonthFor(category: category.id))
                    }
                    Menu {
                        ForEach([3, 6, 12], id: \.self) { months in
                            Button(months == 12 ? "Yearly Average" : "\(months)-Month Average") {
                                run(.setAverageFor(category: category.id, months: months))
                            }
                        }
                    } label: { Label("Set to Average", systemImage: "chart.line.flattrend.xyaxis") }
                }.disabled(model.isBusy)
                Section {
                    // As in Actual's balance menu, a positive balance can move, and overspending can be covered.
                    if model.budget?.budgetType == .envelope {
                        if current.balance > 0 {
                            NavigationLink(value: BudgetRoute.move(.transfer(from: category.id))) {
                                Label("Transfer to Another Category", systemImage: "arrow.right.circle")
                            }
                        }
                        if current.balance < 0 {
                            NavigationLink(value: BudgetRoute.move(.cover(category: category.id))) {
                                Label("Cover Overspending", systemImage: "arrow.uturn.left.circle")
                            }
                        }
                    }
                    Toggle("Rollover Overspending", isOn: Binding(
                        get: { current.carryover },
                        set: { enabled in
                            Task { await model.budgetAction(.rollover(category: category.id, enabled: enabled), month: month) }
                        }))
                } header: { Text("Balance") } footer: {
                    Text("With rollover, overspending carries into next month’s balance instead of reducing To Budget. It applies from this month onward.")
                }.disabled(model.isBusy)
                if let validation { Section { Text(validation).foregroundStyle(.red) } }
                if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
            }
            .navigationTitle(category.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.isBusy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let cents = Money.parse(amount) else { validation = "Enter an amount or calculation, with no more than two decimal places."; return }
                        validation = nil
                        Task {
                            if await model.perform("budget", arguments: ["month": .string(month), "categoryId": .string(category.id), "amount": .number(cents)]) { dismiss() }
                        }
                    }.disabled(model.isBusy).bold()
                }
            }
            .navigationDestination(for: TargetsRoute.self) { _ in
                TargetsEditor(category: current, month: month, path: $path)
            }
            .navigationDestination(for: BudgetRoute.self) { route in
                BudgetRouteView(route: route, month: month) { dismiss() }
            }
            .onAppear {
                // Also runs when returning from targets; keep what was typed.
                guard !didAppear else { return }
                didAppear = true
                amount = Money.editable(category.budgeted)
            }
            .interactiveDismissDisabled(model.isBusy || !path.isEmpty)
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .onChange(of: path.isEmpty) { _, isEmpty in if !isEmpty { detent = .large } }
    }
}
