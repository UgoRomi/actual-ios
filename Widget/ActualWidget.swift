import SwiftUI
import WidgetKit

/// Shows the budget's To Budget (or savings) and the categories that need attention,
/// from the snapshot the app writes after each load.
struct BudgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct BudgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> BudgetEntry { BudgetEntry(date: Date(), snapshot: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (BudgetEntry) -> Void) {
        completion(BudgetEntry(date: Date(), snapshot: context.isPreview ? .placeholder : WidgetSnapshot.read() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BudgetEntry>) -> Void) {
        // The app reloads the widget when the budget changes; this is a fallback.
        let entry = BudgetEntry(date: Date(), snapshot: WidgetSnapshot.read())
        completion(Timeline(entries: [entry], policy: .after(Date(timeIntervalSinceNow: 60 * 60))))
    }
}

private let purple = Color(red: 0.49, green: 0.23, blue: 0.93)

struct BudgetWidgetView: View {
    let entry: BudgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .accessoryInline:
                    Text("\(snapshot.headline): \(snapshot.amount)")
                case .accessoryRectangular:
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snapshot.headline).font(.caption2).foregroundStyle(.secondary)
                        Text(snapshot.amount).font(.headline).monospacedDigit()
                        if let first = snapshot.categories.first {
                            Text("\(first.name) \(first.balance)").font(.caption2).lineLimit(1)
                        }
                    }
                case .systemSmall:
                    headline(snapshot)
                default:
                    HStack(alignment: .top, spacing: 16) {
                        headline(snapshot)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(snapshot.categories.prefix(4).enumerated()), id: \.offset) { _, category in
                                HStack {
                                    Text(category.name).font(.caption).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(category.balance).font(.caption.weight(.semibold)).monospacedDigit()
                                        .foregroundStyle(category.overspent ? Color.red : Color.primary)
                                }
                            }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: "chart.pie.fill").foregroundStyle(purple)
                    Text("Open Actual to show your budget here.").font(.caption)
                }
            }
        }
        .widgetURL(URL(string: "actualnative://budget"))
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    private func headline(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(snapshot.budgetName, systemImage: "chart.pie.fill").font(.caption2).foregroundStyle(purple).lineLimit(1)
            Spacer(minLength: 0)
            Text(snapshot.headline).font(.caption).foregroundStyle(.secondary)
            Text(snapshot.amount).font(.title2.bold()).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                .foregroundStyle(snapshot.negative ? Color.red : Color.primary)
            Text(snapshot.month).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct BudgetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BudgetWidget", provider: BudgetProvider()) { entry in
            BudgetWidgetView(entry: entry)
        }
        .configurationDisplayName("Budget")
        .description("What you have left to budget, and the categories that need attention.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct ActualWidgets: WidgetBundle {
    var body: some Widget { BudgetWidget() }
}
