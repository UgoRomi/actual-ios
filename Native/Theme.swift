import SwiftUI

enum ActualTheme {
    static let purple = Color(red: 135 / 255, green: 25 / 255, blue: 224 / 255)
    static let navy = Color(red: 29 / 255, green: 35 / 255, blue: 66 / 255)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
}

struct MoneyText: View {
    let value: Int
    var currency = ""
    /// Transaction amounts show income in green.
    var positiveColor = Color.primary
    var body: some View {
        Text(Money.formatted(value, currency: currency))
            .monospacedDigit()
            .foregroundStyle(value < 0 ? Color.red : value > 0 ? positiveColor : Color.primary)
    }
}

/// A choice in a list, checked when selected.
struct CheckRow: View {
    let title: String
    var detail: String? = nil
    let selected: Bool
    var body: some View {
        HStack {
            Text(title).foregroundStyle(Color.primary)
            Spacer()
            if let detail { Text(detail).font(.caption).foregroundStyle(Color.secondary) }
            if selected { Image(systemName: "checkmark").foregroundStyle(ActualTheme.purple) }
        }
    }
}

extension Optional {
    /// Whether there is a value; setting false clears it. Binds sheets and dialogs
    /// to optional state: `isPresented: $selection.isPresent`.
    var isPresent: Bool {
        get { self != nil }
        set { if !newValue { self = nil } }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

struct ErrorNotice: View {
    let message: String
    var retry: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Something needs attention", systemImage: "exclamationmark.circle")
                .font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            if let retry { Button("Try again", action: retry).buttonStyle(.bordered) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(ActualTheme.surface, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain)
    }
}
