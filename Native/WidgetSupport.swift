import BackgroundTasks
import Foundation
import WidgetKit

/// Keeps the home-screen widget current, and refreshes the budget while the app is in the background.
@MainActor
enum WidgetSupport {
    /// Also listed in the app's Info.plist as a permitted background task.
    static let refreshTask = "com.ugoromi.actualnative.refresh"

    /// Writes what the widget shows from the open budget, then asks WidgetKit to reload.
    static func update(from model: AppModel) {
        guard let overview = model.overview, let budget = model.budget else {
            if !model.isBudgetOpen { WidgetSnapshot.clear(); WidgetCenter.shared.reloadAllTimelines() }
            return
        }
        let amount = budget.headlineAmount
        let headline = switch budget.budgetType {
        case .envelope: amount < 0 ? "Overbudgeted" : "To Budget"
        case .tracking: budget.savedIsProjected ? "Projected savings" : "Saved"
        }
        let attention = budget.visibleGroups.flatMap(\.categories).filter { !$0.isIncome }
            .sorted { $0.balance < $1.balance }.prefix(4)
        let theme = ThemeStore.shared.theme
        let snapshot = WidgetSnapshot(
            budgetName: overview.budgetName,
            month: model.selectedMonth.formatted(.dateTime.month(.wide).year()),
            headline: headline,
            amount: Money.formatted(amount, currency: model.currency),
            negative: amount < 0,
            categories: attention.map {
                .init(name: $0.name, balance: Money.formatted($0.balance, currency: model.currency), overspent: $0.balance < 0)
            },
            accentColor: .init(light: theme.light.accent, dark: theme.dark.accent),
            negativeColor: theme.light.negative.flatMap { light in
                theme.dark.negative.map { .init(light: light, dark: $0) }
            })
        guard snapshot != WidgetSnapshot.read() else { return }
        snapshot.write()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Asks iOS to refresh the budget in the background, about every half hour at most.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
