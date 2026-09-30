import Foundation

/// What the home-screen widget shows, written by the app to the shared App Group container.
/// Amounts are formatted by the app, in the budget's number format, so the widget needs no engine.
struct WidgetSnapshot: Codable, Sendable, Equatable {
    struct Category: Codable, Sendable, Equatable {
        let name: String
        let balance: String
        /// Negative balances show in red, as Actual's budget does.
        let overspent: Bool
    }

    /// A theme color as #RRGGBB, for light and dark appearance.
    struct Tone: Codable, Sendable, Equatable {
        let light: String
        let dark: String
    }

    let budgetName: String
    /// Such as "September 2026".
    let month: String
    /// "To Budget", "Overbudgeted", "Saved", or "Projected savings".
    let headline: String
    let amount: String
    let negative: Bool
    /// Categories that need attention: overspent first, then the lowest balances.
    let categories: [Category]
    /// The theme's accent and overspending colors. Without them the widget uses Actual's purple and iOS's red.
    var accentColor: Tone?
    var negativeColor: Tone?

    static let appGroup = "group.com.ugoromi.actualnative"
    static let fileName = "widget-snapshot.json"

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName)
    }

    static func read() -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    func write() {
        guard let url = Self.url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Removes the snapshot, such as when a budget is closed.
    static func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static let placeholder = WidgetSnapshot(
        budgetName: "My Budget", month: "September", headline: "To Budget", amount: "1,250.00", negative: false,
        categories: [.init(name: "Groceries", balance: "-32.10", overspent: true),
                     .init(name: "Dining Out", balance: "18.40", overspent: false),
                     .init(name: "Fuel", balance: "42.00", overspent: false)])
}
