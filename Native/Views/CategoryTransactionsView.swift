import SwiftUI

/// A category's transactions for a month, or every uncategorized transaction,
/// as Actual's mobile category and uncategorized pages list them.
struct CategoryTransactionsView: View {
    let filter: CategoryEntry.Filter
    let title: String
    @Environment(AppModel.self) private var model
    @State private var selected: Transaction?

    private var entries: [CategoryEntry] {
        CategoryEntry.entries(model.transactions, filter: filter, accounts: model.overview?.accounts ?? [])
    }

    var body: some View {
        let entries = entries
        let days = Dictionary(grouping: entries, by: \.transaction.date)
        List {
            if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
            if entries.isEmpty {
                ContentUnavailableView(filter == .uncategorized ? "Everything is categorized" : "No transactions",
                                       systemImage: filter == .uncategorized ? "checkmark.circle" : "tray",
                                       description: Text(filter == .uncategorized
                                                         ? "Every transaction in your budget has a category."
                                                         : "Nothing was spent or received in this category this month."))
            } else {
                Section {
                    LabeledContent("Total") {
                        MoneyText(value: entries.reduce(0) { $0 + $1.amount }, currency: model.currency)
                            .font(.headline)
                    }
                } footer: {
                    if filter == .uncategorized {
                        Text("Tap a transaction to choose its category.")
                    }
                }
            }
            ForEach(days.keys.sorted(by: >), id: \.self) { day in
                Section {
                    ForEach(days[day] ?? []) { entry in
                        Button { selected = entry.transaction } label: { row(entry) }
                            .buttonStyle(.plain).disabled(model.isBusy)
                    }
                } header: {
                    if let date = BudgetDate.date(day) { Text(date, format: .dateTime.weekday(.wide).month(.abbreviated).day()) }
                }
            }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { transaction in
            TransactionEditor(transaction: transaction, accountID: transaction.accountId)
        }
    }

    private func row(_ entry: CategoryEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.transaction.title).font(.body.weight(.medium))
                Text([entry.part == nil ? nil : "Part of a split",
                      model.overview?.accounts.first { $0.id == entry.transaction.accountId }?.name]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if let notes = entry.notes, !notes.isEmpty {
                    Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            MoneyText(value: entry.amount, currency: model.currency, positiveColor: .green).font(.body.weight(.semibold))
        }.padding(.vertical, 4).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }
}
