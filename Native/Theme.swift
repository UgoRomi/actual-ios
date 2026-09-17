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
    var body: some View {
        Text(Money.formatted(value, currency: currency))
            .monospacedDigit()
            .foregroundStyle(value < 0 ? Color.red : Color.primary)
    }
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
