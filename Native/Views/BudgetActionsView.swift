import SwiftUI

/// Moves money as Actual's mobile Transfer and Cover modals do: an amount, and
/// the category or To Budget it moves to or from.
struct MoveMoneyForm: View {
    enum Kind: Hashable {
        /// Part of a category's balance to another category or To Budget.
        case transfer(from: String)
        /// A category's overspending, from another category or To Budget.
        case cover(category: String)
        /// Money left in To Budget, to a category.
        case budgetAvailable
        /// A negative To Budget, from a category's balance.
        case coverOverbudgeted
    }

    let kind: Kind
    let month: String
    var onDone: () -> Void
    @Environment(AppModel.self) private var model
    @State private var amount = ""
    @State private var selection: BudgetSource?
    @State private var validation: String?
    @State private var initialized = false

    private var budget: BudgetMonth? { model.budget }
    private func category(_ id: String) -> BudgetCategory? { budget?.categories.first { $0.id == id } }

    private var title: String {
        switch kind {
        case .transfer(let id), .cover(let id): category(id)?.name ?? "Category"
        case .budgetAvailable: "Move to a Category"
        case .coverOverbudgeted: "Cover from a Category"
        }
    }
    private var amountHeader: String {
        switch kind {
        case .transfer, .budgetAvailable: "Transfer this amount"
        case .cover, .coverOverbudgeted: "Cover this amount"
        }
    }
    /// Money moves to the chosen place when transferring, and from it when covering.
    private var movesToChoice: Bool {
        switch kind { case .transfer, .budgetAvailable: true; case .cover, .coverOverbudgeted: false }
    }
    private var offersToBudget: Bool {
        switch kind { case .transfer, .cover: true; case .budgetAvailable, .coverOverbudgeted: false }
    }
    private var excluded: String? {
        switch kind { case .transfer(let id), .cover(let id): id; default: nil }
    }
    private var groups: [CategoryGroup] {
        (budget?.visibleGroups ?? []).compactMap { group in
            let categories = group.categories.filter { !$0.isIncome && $0.id != excluded }
            return categories.isEmpty ? nil : CategoryGroup(id: group.id, name: group.name, categories: categories)
        }
    }
    private var initialAmount: Int {
        switch kind {
        case .transfer(let id): max(category(id)?.balance ?? 0, 0)
        case .cover(let id): abs(min(category(id)?.balance ?? 0, 0))
        case .budgetAvailable: max(budget?.toBudget ?? 0, 0)
        case .coverOverbudgeted: abs(min(budget?.toBudget ?? 0, 0))
        }
    }

    var body: some View {
        ThemedForm {
            Section {
                AmountField(label: amountHeader, text: $amount, large: true, focusesOnAppear: true)
            } header: { Text(amountHeader) } footer: {
                if case .cover = kind { Text("Actual covers no more than the source has available.") }
            }
            if offersToBudget {
                Section(movesToChoice ? "To" : "From") {
                    choice(.toBudget, name: "To Budget", balance: budget?.toBudget)
                }
            }
            ForEach(groups) { group in
                Section(group.name) {
                    ForEach(group.categories) { category in
                        choice(.category(category.id), name: category.name, balance: category.balance)
                    }
                }
            }
            if let validation { Section { Text(validation).foregroundStyle(ActualTheme.negative) } }
            if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Transfer") { submit() }.bold().disabled(model.isBusy)
            }
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            amount = Money.editable(initialAmount)
        }
    }

    private func choice(_ source: BudgetSource, name: String, balance: Int?) -> some View {
        Button { selection = source } label: {
            HStack {
                Text(name).foregroundStyle(Color.primary)
                Spacer()
                if let balance {
                    Text(Money.formatted(balance, currency: model.currency)).monospacedDigit()
                        .font(.subheadline).foregroundStyle(balance < 0 ? ActualTheme.negative : Color.secondary)
                }
                if selection == source { Image(systemName: "checkmark").foregroundStyle(ActualTheme.accent) }
            }
        }
        .accessibilityAddTraits(selection == source ? .isSelected : [])
    }

    private func submit() {
        guard let cents = Money.parse(amount), cents > 0 else {
            validation = "Enter an amount greater than zero, with no more than two decimal places."
            return
        }
        guard let selection else {
            validation = movesToChoice ? "Choose where the money goes." : "Choose where the money comes from."
            return
        }
        validation = nil
        let action: BudgetAction
        switch (kind, selection) {
        case (.transfer(let from), _): action = .transfer(from: from, to: selection, amount: cents)
        case (.cover(let category), _): action = .coverOverspending(category: category, from: selection, amount: cents)
        case (.budgetAvailable, .category(let id)): action = .transferAvailable(to: id, amount: cents)
        case (.coverOverbudgeted, .category(let id)): action = .coverOverbudgeted(from: id, amount: cents)
        default: return
        }
        Task { if await model.budgetAction(action, month: month) { onDone() } }
    }
}

/// Holds money left to budget for next month, as Actual's Hold for next month does.
struct HoldForm: View {
    let month: String
    var onDone: () -> Void
    @Environment(AppModel.self) private var model
    @State private var amount = ""
    @State private var validation: String?
    @State private var initialized = false

    var body: some View {
        ThemedForm {
            Section {
                AmountField(label: "Hold this amount", text: $amount, large: true, focusesOnAppear: true)
            } header: { Text("Hold this amount") } footer: {
                Text("Held money leaves this month’s To Budget and becomes available to budget next month.")
            }
            if let validation { Section { Text(validation).foregroundStyle(ActualTheme.negative) } }
            if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
        }
        .navigationTitle("Hold for Next Month").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Hold") {
                    guard let cents = Money.parse(amount), cents > 0 else {
                        validation = "Enter an amount greater than zero, with no more than two decimal places."
                        return
                    }
                    validation = nil
                    Task { if await model.budgetAction(.hold(amount: cents), month: month) { onDone() } }
                }.bold().disabled(model.isBusy)
            }
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            amount = Money.editable(max(model.budget?.toBudget ?? 0, 0))
        }
    }
}

enum BudgetRoute: Hashable, Identifiable {
    case move(MoveMoneyForm.Kind)
    case hold
    /// Overspent categories to choose one to cover.
    case overspent
    /// Transactions in a category for a month, or every uncategorized transaction.
    case transactions(CategoryEntry.Filter, title: String)
    var id: Self { self }
}

/// Actual's envelope budget summary: how To Budget adds up, and its menu actions.
struct EnvelopeSummarySheet: View {
    let month: String
    let monthDate: Date
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ThemedForm {
                if let budget = model.budget, let summary = budget.envelope {
                    let toBudget = budget.toBudget ?? 0
                    Section {
                        LabeledContent(toBudget < 0 ? "Overbudgeted" : "To Budget") {
                            Text(Money.formatted(toBudget, currency: model.currency))
                                .font(.title2.bold()).monospacedDigit()
                                .foregroundStyle(toBudget < 0 ? ActualTheme.negative : Color.primary)
                        }
                    }
                    Section("How it adds up") {
                        row("Income", summary.income)
                        row("From last month", summary.fromLastMonth)
                        row("Available funds", summary.availableFunds, bold: true)
                        row("Overspent in \(previousMonthName)", summary.lastMonthOverspent)
                        row("Budgeted", summary.budgeted)
                        // Actual shows what is held as a deduction.
                        row("For next month", -summary.forNextMonth)
                    }
                    Section("Actions") {
                        if toBudget > 0 {
                            NavigationLink(value: BudgetRoute.move(.budgetAvailable)) {
                                Label("Move to a Category", systemImage: "arrow.right.circle")
                            }
                            if summary.autoHold == 0 {
                                NavigationLink(value: BudgetRoute.hold) {
                                    Label("Hold for Next Month", systemImage: "calendar.badge.clock")
                                }
                            }
                        }
                        if toBudget < 0 {
                            NavigationLink(value: BudgetRoute.move(.coverOverbudgeted)) {
                                Label("Cover from a Category", systemImage: "arrow.uturn.left.circle")
                            }
                        }
                        if summary.forNextMonth > 0 && summary.manualHold == 0 {
                            Button("Disable Current Auto Hold", systemImage: "pause.circle") {
                                Task { await model.budgetAction(.disableAutoHold, month: month) }
                            }
                        }
                        if summary.forNextMonth > 0 && summary.manualHold != 0 {
                            Button("Reset Next Month’s Buffer", systemImage: "arrow.counterclockwise") {
                                Task { await model.budgetAction(.resetHold, month: month) }
                            }
                        }
                        if toBudget == 0 && summary.forNextMonth == 0 {
                            Text("No actions available").foregroundStyle(.secondary)
                        }
                    }.disabled(model.isBusy)
                }
                if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
            }
            .navigationTitle("Budget Summary").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(for: BudgetRoute.self) { route in
                BudgetRouteView(route: route, month: month) { path = NavigationPath() }
            }
        }
    }

    private var previousMonthName: String {
        let previous = Calendar(identifier: .gregorian).date(byAdding: .month, value: -1, to: monthDate) ?? monthDate
        return previous.formatted(.dateTime.month(.wide))
    }

    private func row(_ title: String, _ value: Int, bold: Bool = false) -> some View {
        LabeledContent(title) {
            Text(Money.formatted(value, currency: model.currency)).monospacedDigit()
                .fontWeight(bold ? .semibold : .regular)
        }
    }
}

/// The destination for a budget route, returning with `onDone` once its action is saved.
struct BudgetRouteView: View {
    let route: BudgetRoute
    let month: String
    var onDone: () -> Void

    var body: some View {
        switch route {
        case .move(let kind): MoveMoneyForm(kind: kind, month: month, onDone: onDone)
        case .hold: HoldForm(month: month, onDone: onDone)
        case .overspent: OverspentList()
        case .transactions(let filter, let title): CategoryTransactionsView(filter: filter, title: title)
        }
    }
}

/// Overspent categories, to choose one to cover, as Actual's overspending banner lists them.
struct OverspentList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ThemedList {
            ForEach(model.budget?.overspent ?? []) { category in
                NavigationLink(value: BudgetRoute.move(.cover(category: category.id))) {
                    LabeledContent(category.name) {
                        Text(Money.formatted(category.balance, currency: model.currency))
                            .monospacedDigit().foregroundStyle(ActualTheme.negative)
                    }
                }
            }
        }
        .overlay {
            if model.budget?.overspent.isEmpty != false {
                ContentUnavailableView("Nothing overspent", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle("Cover Overspending").navigationBarTitleDisplayMode(.inline)
    }
}

/// A sheet for one budget route, such as covering overspending from a banner.
struct BudgetRouteSheet: View {
    let route: BudgetRoute
    let month: String
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            BudgetRouteView(route: route, month: month) { dismiss() }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.isBusy) }
                }
                .navigationDestination(for: BudgetRoute.self) { next in
                    BudgetRouteView(route: next, month: month) { dismiss() }
                }
        }
    }
}

/// Actual's mobile budget banners: overspent categories, and budgeting more than is available.
struct BudgetBanners: View {
    let budget: BudgetMonth
    var onOpen: (BudgetRoute) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let overspent = budget.overspent
        VStack(spacing: 10) {
            if !overspent.isEmpty {
                let total = overspent.reduce(0) { $0 + $1.balance }
                banner(
                    "\(overspent.count) overspent \(overspent.count == 1 ? "category" : "categories") (\(Money.formatted(total, currency: model.currency)))",
                    systemImage: "exclamationmark.triangle.fill",
                    // Tracking budgets have no money to move, as in Actual.
                    action: budget.budgetType == .envelope ? "Cover" : nil
                ) { onOpen(.overspent) }
            }
            let uncategorized = CategoryEntry.entries(model.transactions, filter: .uncategorized,
                                                      accounts: model.overview?.accounts ?? [])
            if !uncategorized.isEmpty {
                let total = uncategorized.reduce(0) { $0 + $1.amount }
                banner(
                    "\(uncategorized.count) uncategorized \(uncategorized.count == 1 ? "transaction" : "transactions") (\(Money.formatted(total, currency: model.currency)))",
                    systemImage: "tag", action: "Categorize", tint: ActualTheme.warning
                ) { onOpen(.transactions(.uncategorized, title: "Uncategorized")) }
            }
            if budget.budgetType == .envelope, let toBudget = budget.toBudget, toBudget < 0 {
                banner("You have budgeted more than your available funds", systemImage: "arrow.down.circle.fill",
                       action: "Cover") { onOpen(.move(.coverOverbudgeted)) }
            }
        }
    }

    private func banner(_ text: String, systemImage: String, action: String?, tint: Color = ActualTheme.negative,
                        perform: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Label(text, systemImage: systemImage).font(.subheadline.weight(.medium))
                .symbolRenderingMode(.multicolor)
            Spacer(minLength: 8)
            if let action {
                Button(action, action: perform).buttonStyle(.glass).controlSize(.small).disabled(model.isBusy)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
    }
}
