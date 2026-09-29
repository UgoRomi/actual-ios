import SwiftUI

struct BudgetView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedCategory: BudgetCategory?
    @State private var confirmOverwrite = false
    @State private var pendingMonthAction: BudgetAction?
    @State private var showsSummary = false
    @State private var route: BudgetRoute?
    @State private var managedGroup: String?
    @State private var managedCategory: String?
    @State private var addingGroup = false
    @State private var editingMonthNotes = false
    /// Like Actual's "Show hidden categories", remembered on this device.
    @AppStorage("budget.showHiddenCategories") private var showsHidden = false
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
                        if budget.budgetType == .envelope {
                            Button { showsSummary = true } label: { summary(budget) }
                                .buttonStyle(.plain).disabled(model.isBusy)
                                .accessibilityHint("Show how To Budget adds up, and move money")
                        } else { summary(budget) }
                        BudgetBanners(budget: budget) { route = $0 }
                        if budget.groups.isEmpty {
                            ContentUnavailableView {
                                Label("No categories yet", systemImage: "tray")
                            } description: {
                                Text("Add a category group to start planning your money.")
                            } actions: {
                                Button("Add Category Group") { addingGroup = true }.buttonStyle(.glass)
                            }
                        } else {
                            filterBar(budget)
                            categoryList(budget.expenseGroups(filter, showingHidden: showsHidden))
                            // Income, as Actual's mobile budget lists it after expenses.
                            if filter == .all { incomeList(budget) }
                        }
                        SyncFooter()
                    }
                }.padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: 760).frame(maxWidth: .infinity)
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
            .sheet(isPresented: Binding(get: { managedGroup != nil }, set: { if !$0 { managedGroup = nil } })) {
                if let managedGroup { GroupManageSheet(groupID: managedGroup) }
            }
            .sheet(isPresented: Binding(get: { managedCategory != nil }, set: { if !$0 { managedCategory = nil } })) {
                if let managedCategory { CategoryManageSheet(categoryID: managedCategory) }
            }
            .sheet(isPresented: $addingGroup) {
                NameSheet(title: "New Category Group", action: "Add") { name in
                    await model.manage("createCategoryGroup", ["name": .string(name)])
                }
            }
            .sheet(isPresented: $editingMonthNotes) {
                NotesSheet(id: "budget-\(model.month)",
                           title: model.selectedMonth.formatted(.dateTime.month(.wide).year()),
                           initial: model.budget?.notes ?? "")
            }
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
            Section {
                Button("Month Notes", systemImage: "note.text") { editingMonthNotes = true }
                Button("Add Category Group", systemImage: "folder.badge.plus") { addingGroup = true }
                Toggle(isOn: $showsHidden) { Label("Show Hidden Categories", systemImage: "eye") }
            }
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
                    filterChip(option, count: budget.count(option, showingHidden: showsHidden))
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

    /// Income groups, received this month, and in tracking budgets what was budgeted.
    @ViewBuilder
    private func incomeList(_ budget: BudgetMonth) -> some View {
        ForEach(budget.groups(showingHidden: showsHidden).filter(\.isIncome)) { group in
            VStack(alignment: .leading, spacing: 6) {
                groupHeader(group)
                VStack(spacing: 0) {
                    ForEach(group.categories) { category in
                        if category.id != group.categories.first?.id { Divider().padding(.leading, 16) }
                        Button {
                            // Envelope budgets do not budget income.
                            if budget.budgetType == .tracking { selectedCategory = category }
                            else { managedCategory = category.id }
                        } label: { incomeRow(category) }
                            .buttonStyle(.plain).disabled(model.isBusy)
                            .opacity(category.hidden ? 0.5 : 1)
                    }
                }.background(ActualTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            }.padding(.bottom, 12)
        }
    }

    private func incomeRow(_ category: BudgetCategory) -> some View {
        columns {
            Text(category.name).lineLimit(2)
        } budgeted: {
            if model.budget?.budgetType == .tracking {
                amount(category.budgeted).font(.subheadline).foregroundStyle(.secondary)
            }
        } balance: {
            amount(category.spent).font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                .padding(.horizontal, Self.balanceInset)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(category.name), received \(Money.formatted(category.spent, currency: model.currency))")
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
    /// As in Actual's mobile budget, tapping the group opens its menu.
    private func groupHeader(_ group: CategoryGroup) -> some View {
        let budgeted = Money.formatted(group.budgeted, currency: model.currency)
        let balance = Money.formatted(group.balance, currency: model.currency)
        let name = HStack(spacing: 4) {
            Text(group.name).lineLimit(2)
            if group.hidden { Image(systemName: "eye.slash").font(.caption).foregroundStyle(.secondary) }
            Image(systemName: "chevron.down").font(.caption2.bold()).foregroundStyle(.secondary)
        }
        return Button { managedGroup = group.id } label: { Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    name.font(.headline)
                    Text("Budgeted \(budgeted) · Balance \(balance)").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                columns { name.font(.headline) } budgeted: { amount(group.budgeted) } balance: {
                    amount(group.balance).padding(.horizontal, Self.balanceInset)
                }
                .font(.subheadline.weight(.semibold))
            }
        }.contentShape(Rectangle()) }
        .buttonStyle(.plain).disabled(model.isBusy)
        .padding(.horizontal, 16)
        .opacity(group.hidden ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.name)\(group.hidden ? ", hidden" : ""), Budgeted \(budgeted), Balance \(balance)")
        .accessibilityHint("Group options")
        .accessibilityIdentifier("group-header")
        .accessibilityAddTraits([.isHeader, .isButton])
    }

    private func categoryButton(_ category: BudgetCategory) -> some View {
        let status = TargetStatus(category)
        let label: [String?] = [
            category.name, category.hidden ? "hidden" : nil, category.hasTargets ? "Has targets" : nil,
            "Budgeted \(Money.formatted(category.budgeted, currency: model.currency))",
            "Balance \(Money.formatted(category.balance, currency: model.currency))",
            status.label(currency: model.currency),
        ]
        return Button { selectedCategory = category } label: {
            categoryRow(category, status: status)
        }
        .buttonStyle(.plain).disabled(model.isBusy)
        .opacity(category.hidden ? 0.5 : 1)
        .contextMenu {
            Button("Edit Category", systemImage: "pencil") { managedCategory = category.id }
        }
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
                Section {
                    NavigationLink(value: BudgetRoute.transactions(.category(id: category.id, month: month), title: category.name)) {
                        Label("Transactions", systemImage: "list.bullet.rectangle")
                    }.accessibilityIdentifier("category-transactions")
                    NavigationLink(value: ManageCategoryRoute()) {
                        Label("Edit Category", systemImage: "pencil")
                    }
                } footer: { Text("Rename, add notes, hide, reorder, move to another group, or delete.") }
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
            .navigationDestination(for: ManageCategoryRoute.self) { _ in
                CategoryManageForm(categoryID: category.id) { dismiss() }
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
