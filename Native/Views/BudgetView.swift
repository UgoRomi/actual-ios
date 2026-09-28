import SwiftUI

struct BudgetView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedCategory: BudgetCategory?
    @State private var confirmOverwrite = false
    @State private var filter = BudgetFilter.all
    /// Fits most amounts; longer ones shrink to fit.
    @ScaledMetric(relativeTo: .subheadline) private var amountWidth: CGFloat = 80
    /// Room around a balance for its colored background.
    private static let balanceInset: CGFloat = 6

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    monthControl
                    if let error = model.errorMessage { ErrorNotice(message: error) { Task { await model.refresh() } } }
                    if let budget = model.budget {
                        summary(budget)
                        if budget.groups.isEmpty {
                            ContentUnavailableView("No categories yet", systemImage: "tray", description: Text("Set up categories in Actual to start planning your money."))
                        } else {
                            filterBar(budget)
                            categoryList(budget.expenseGroups(filter))
                        }
                        SyncFooter()
                    }
                }.padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .background(ActualTheme.background)
            .navigationTitle("Budget")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { targetsMenu }
                ToolbarItem(placement: .topBarTrailing) { SettingsButton() }
            }
            .refreshable { await model.refresh() }
            .sheet(item: $selectedCategory) { category in BudgetEditor(category: category, month: model.month) }
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

    /// Actual's budget month menu actions for targets.
    private var targetsMenu: some View {
        Menu("Targets", systemImage: "target") {
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
        .disabled(model.isBusy || model.budget == nil)
    }

    private var monthControl: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedMonth, format: .dateTime.month(.wide).year()).font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(model.overview?.budgetName ?? "Actual")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button("Previous month", systemImage: "chevron.left") { Task { await model.moveMonth(-1) } }
                Button("Next month", systemImage: "chevron.right") { Task { await model.moveMonth(1) } }
            }.labelStyle(.iconOnly).buttonStyle(.glass).disabled(model.isBusy)
        }
    }

    private func summary(_ budget: BudgetMonth) -> some View {
        let headline = SummaryHeadline(budget)
        let title = Label(headline.title, systemImage: headline.systemImage)
            .font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.8))
        let amount = Text(Money.formatted(headline.amount, currency: model.currency))
            .font(.system(.title, design: .rounded, weight: .bold)).monospacedDigit()
            .foregroundStyle(.white)
        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) { title; Spacer(minLength: 0); amount }
                VStack(alignment: .leading, spacing: 2) { title; amount.fixedSize(horizontal: false, vertical: true) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    summaryValue("Budgeted", budget.totalBudgeted)
                    Spacer(minLength: 0)
                    summaryValue("Spent", budget.totalSpent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    summaryValue("Budgeted", budget.totalBudgeted)
                    summaryValue("Spent", budget.totalSpent)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(ActualTheme.navy.gradient, in: RoundedRectangle(cornerRadius: 22))
    }

    private func summaryValue(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.white.opacity(0.7))
            Text(Money.formatted(value, currency: model.currency)).fontWeight(.semibold).monospacedDigit().foregroundStyle(.white)
        }.font(.subheadline).accessibilityElement(children: .combine)
    }

    /// Quick filters, with how many categories each shows. Underfunded appears once targets set goals.
    private func filterBar(_ budget: BudgetMonth) -> some View {
        let hasGoals = budget.categories.contains { !$0.isIncome && $0.goal != nil }
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(BudgetFilter.allCases.filter { $0 != .underfunded || hasGoals || filter == $0 }) { option in
                    filterChip(option, count: budget.count(option))
                }
            }
        }
        .scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        // Scrolls to the screen edges while lining up with the content.
        .contentMargins(.horizontal, 16, for: .scrollContent).padding(.horizontal, -16)
    }

    private func filterChip(_ option: BudgetFilter, count: Int) -> some View {
        let selected = filter == option
        let tint: Color = option == .overspent ? .red : .orange
        return Button {
            withAnimation(.snappy) { filter = option }
        } label: {
            HStack(spacing: 6) {
                Text(option.title)
                if option != .all {
                    Text(count, format: .number)
                        .font(.caption.bold()).monospacedDigit()
                        .foregroundStyle(selected ? Color.white : count > 0 ? tint : Color.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(selected ? Color.white.opacity(0.22) : count > 0 ? tint.opacity(0.14) : Color.secondary.opacity(0.12), in: Capsule())
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(selected ? ActualTheme.purple : ActualTheme.surface, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityValue(option == .all ? Text("") : Text("^[\(count) category](inflect: true)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func categoryList(_ groups: [CategoryGroup]) -> some View {
        if groups.isEmpty, filter != .all {
            ContentUnavailableView {
                Label(filter == .overspent ? "No overspent categories" : "No underfunded categories", systemImage: "checkmark.circle")
            } description: {
                Text(filter == .overspent ? "Every category has money left this month." : "Every category has what its targets ask for this month.")
            } actions: {
                Button("Show All Categories") { withAnimation(.snappy) { filter = .all } }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !dynamicTypeSize.isAccessibilitySize {
                    columns { Spacer(minLength: 0) } budgeted: { Text("Budgeted") } balance: {
                        Text("Balance").padding(.horizontal, Self.balanceInset)
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
                    .accessibilityHidden(true)
                }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        groupHeader(group)
                        VStack(spacing: 0) {
                            ForEach(group.categories) { category in
                                if category.id != group.categories.first?.id { Divider().padding(.leading, 16) }
                                categoryButton(category)
                            }
                        }.background(ActualTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                    }.padding(.bottom, 12)
                }
            }
        }
    }

    /// A name, then budgeted and balance amounts in columns that line up across group headers and rows.
    private func columns<Name: View, Budgeted: View, Balance: View>(
        @ViewBuilder name: () -> Name, @ViewBuilder budgeted: () -> Budgeted, @ViewBuilder balance: () -> Balance
    ) -> some View {
        HStack(spacing: 8) {
            name().frame(maxWidth: .infinity, alignment: .leading)
            budgeted().frame(width: amountWidth, alignment: .trailing)
            balance().frame(width: amountWidth + 2 * Self.balanceInset, alignment: .trailing)
        }
    }

    private func amount(_ value: Int) -> some View {
        Text(Money.formatted(value, currency: model.currency))
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
    }

    /// Actual's totals for the whole group, whatever the filter shows.
    private func groupHeader(_ group: CategoryGroup) -> some View {
        let budgeted = Money.formatted(group.budgeted, currency: model.currency)
        let balance = Money.formatted(group.balance, currency: model.currency)
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name).font(.headline)
                    Text("Budgeted \(budgeted) · Balance \(balance)").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                columns { Text(group.name).font(.headline).lineLimit(2) } budgeted: { amount(group.budgeted) } balance: {
                    amount(group.balance).padding(.horizontal, Self.balanceInset)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.name), Budgeted \(budgeted), Balance \(balance)")
        .accessibilityAddTraits(.isHeader)
    }

    private func categoryButton(_ category: BudgetCategory) -> some View {
        let status = TargetStatus(category)
        let label: [String?] = [
            category.name, category.hasTargets ? "Has targets" : nil,
            "Budgeted \(Money.formatted(category.budgeted, currency: model.currency))",
            "Balance \(Money.formatted(category.balance, currency: model.currency))",
            status.label(currency: model.currency),
        ]
        return Button { selectedCategory = category } label: {
            categoryRow(category, status: status)
        }
        .buttonStyle(.plain).disabled(model.isBusy)
        .accessibilityLabel(label.compactMap(\.self).joined(separator: ", "))
        .accessibilityHint("Edit budgeted amount")
    }

    private func categoryRow(_ category: BudgetCategory, status: TargetStatus) -> some View {
        let name = HStack(spacing: 4) {
            Text(category.name).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            if category.hasTargets { Image(systemName: "target").font(.caption).foregroundStyle(.secondary) }
        }
        let balance = amount(category.balance)
            .font(.subheadline.weight(.semibold)).foregroundStyle(status.balanceColor)
            .padding(.horizontal, Self.balanceInset).padding(.vertical, 3)
            .background(status.balanceColor.opacity(status.highlightsBalance ? 0.14 : 0), in: Capsule())
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    name
                    HStack(alignment: .firstTextBaseline) {
                        Text("Budgeted \(Money.formatted(category.budgeted, currency: model.currency))").foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        balance
                    }.font(.subheadline)
                }
            } else {
                columns { name } budgeted: { amount(category.budgeted).font(.subheadline).foregroundStyle(.secondary) } balance: { balance }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
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
    /// Whether the balance has a status color, which rows set on a tinted background.
    var highlightsBalance: Bool { category.balance < 0 || category.goal != nil }
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

    init(_ budget: BudgetMonth) {
        switch budget.budgetType {
        case .envelope:
            amount = budget.toBudget ?? 0
            title = amount < 0 ? "Over budget" : "Available to budget"
            systemImage = amount < 0 ? "exclamationmark.circle" : "circle.dotted"
        case .tracking:
            amount = budget.saved ?? 0
            systemImage = amount < 0 ? "exclamationmark.circle" : "banknote"
            if budget.savedIsProjected {
                title = "Projected savings"
            } else {
                title = amount < 0 ? "Overspent" : "Saved"
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
