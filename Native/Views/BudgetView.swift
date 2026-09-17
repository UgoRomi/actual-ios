import SwiftUI

struct BudgetView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedCategory: BudgetCategory?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    monthControl
                    if let error = model.errorMessage { ErrorNotice(message: error) { Task { await model.refresh() } } }
                    if let snapshot = model.snapshot {
                        summary(snapshot)
                        if snapshot.groups.isEmpty {
                            ContentUnavailableView("No categories yet", systemImage: "tray", description: Text("Set up categories in Actual to start planning your money."))
                        }
                        ForEach(snapshot.groups.filter { $0.categories.contains { !$0.isIncome } }) { group in
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
                ToolbarItem(placement: .topBarLeading) {
                    Text(model.snapshot?.budgetName ?? "Actual").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                ToolbarItem(placement: .topBarTrailing) { SettingsButton() }
            }
            .refreshable { await model.refresh() }
            .sheet(item: $selectedCategory) { category in BudgetEditor(category: category, month: model.month) }
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

    private func summary(_ snapshot: BudgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Label(snapshot.toBudget < 0 ? "Over budget" : "Available to budget", systemImage: snapshot.toBudget < 0 ? "exclamationmark.circle" : "circle.dotted")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                Text(Money.formatted(snapshot.toBudget, currency: model.currency))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold)).monospacedDigit()
                    .foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                Text(snapshot.toBudget == 0 ? "Every bit has a purpose." : snapshot.toBudget < 0 ? "Adjust your plan to bring it back into balance." : "Give your money a purpose, one category at a time.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.8))
            }
            Divider().overlay(.white.opacity(0.2))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) {
                    summaryValue("Budgeted", snapshot.totalBudgeted)
                    Spacer(minLength: 24)
                    summaryValue("Spent", snapshot.totalSpent)
                }
                VStack(alignment: .leading, spacing: 16) {
                    summaryValue("Budgeted", snapshot.totalBudgeted)
                    summaryValue("Spent", snapshot.totalSpent)
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
                Spacer(minLength: 12)
                MoneyText(value: category.balance, currency: model.currency).font(.headline)
            }
            HStack {
                Text("Budgeted \(Money.formatted(category.budgeted, currency: model.currency))")
                Spacer(minLength: 8)
                Text(category.balance < 0 ? "Overspent" : "Available")
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(18).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityHint("Edit budgeted amount")
    }
}

struct BudgetEditor: View {
    let category: BudgetCategory
    let month: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var validation: String?
    @FocusState private var amountFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Budgeted amount", text: $amount)
                        .keyboardType(.numbersAndPunctuation).monospacedDigit().focused($amountFocused)
                        .accessibilityLabel("Budgeted amount")
                } header: { Text("Budgeted for \(month)") } footer: { Text("Set the total amount you want to budget for this category.") }
                Section {
                    LabeledContent("Spent") { MoneyText(value: category.spent, currency: model.currency) }
                    LabeledContent("Available") { MoneyText(value: category.balance, currency: model.currency) }
                }
                if let validation { Section { Text(validation).foregroundStyle(.red) } }
                if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
            }
            .navigationTitle(category.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.isBusy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let cents = Money.parse(amount) else { validation = "Enter an amount with no more than two decimal places."; return }
                        validation = nil
                        Task {
                            if await model.perform("budget", arguments: ["month": .string(month), "categoryId": .string(category.id), "amount": .number(cents)]) { dismiss() }
                        }
                    }.disabled(model.isBusy).bold()
                }
            }
            .onAppear { amount = Money.editable(category.budgeted); amountFocused = true }
            .interactiveDismissDisabled(model.isBusy)
        }.presentationDetents([.medium, .large])
    }
}
