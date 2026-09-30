import SwiftUI

/// The colors of the theme in use. Views that read them redraw when the theme changes.
@MainActor
enum ActualTheme {
    static var accent: Color { palette.accent }
    /// Text and symbols on a filled accent shape.
    static var onAccent: Color { palette.onAccent }
    /// The budget's summary card.
    static var card: AnyShapeStyle { palette.card }
    static var onCard: Color { palette.onCard }
    static var background: Color { palette.background }
    static var surface: Color { palette.surface }
    static var positive: Color { palette.positive }
    static var warning: Color { palette.warning }
    static var negative: Color { palette.negative }

    private static var palette: ThemePalette { ThemeStore.shared.palette }
}

/// The theme in use and the themes made on this device, saved as a device setting.
@MainActor @Observable
final class ThemeStore {
    static let shared = ThemeStore()

    private(set) var settings: ThemeSettings
    private(set) var palette: ThemePalette
    var theme: Theme { settings.theme }

    private init() {
        let settings = ThemeSettings(defaults: .standard)
        self.settings = settings
        palette = ThemePalette(settings.theme)
    }

    func select(_ id: String) {
        change { $0.selection = id }
    }

    /// Adds an editable copy of the theme in use, and switches to it.
    func addCopy() -> Theme {
        var copy: Theme?
        change { copy = $0.addCopy() }
        return copy ?? theme
    }

    func update(_ theme: Theme) {
        change { $0.update(theme) }
    }

    func delete(_ id: String) {
        change { $0.delete(id) }
    }

    private func change(_ edit: (inout ThemeSettings) -> Void) {
        var edited = settings
        edit(&edited)
        guard edited != settings else { return }
        let themeChanged = edited.theme != settings.theme
        settings = edited
        if themeChanged { palette = ThemePalette(edited.theme) }
        edited.save(to: .standard)
    }
}

/// A theme's colors, ready to draw. Each follows the appearance it is drawn in.
struct ThemePalette {
    let accent: Color
    let onAccent: Color
    let card: AnyShapeStyle
    let onCard: Color
    let background: Color
    let surface: Color
    /// Whether the theme sets the page and its rows, rather than following iOS.
    let setsBackground: Bool
    let positive: Color
    let warning: Color
    let negative: Color

    init(_ theme: Theme) {
        self.init(light: theme.light, dark: theme.dark)
    }

    /// One appearance's colors, whatever appearance they are drawn in.
    init(_ colors: ThemeColors) {
        self.init(light: colors, dark: colors)
    }

    private init(light: ThemeColors, dark: ThemeColors) {
        // Without a second color the card keeps the soft shading of a single one.
        let shadesCard = light.cardEnd != nil || dark.cardEnd != nil
        var (light, dark) = (light, dark)
        light.cardEnd = light.cardEnd ?? light.card
        dark.cardEnd = dark.cardEnd ?? dark.card
        func color(_ role: ThemeRole, else system: UIColor = .clear) -> Color {
            let (light, dark) = (UIColor(hex: light[role]) ?? system, UIColor(hex: dark[role]) ?? system)
            return Color(uiColor: UIColor { ($0.userInterfaceStyle == .dark ? dark : light).resolvedColor(with: $0) })
        }
        func text(_ color: KeyPath<ThemeColors, RGB>) -> Color {
            let (light, dark) = (UIColor(light[keyPath: color]), UIColor(dark[keyPath: color]))
            return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
        }
        accent = color(.accent)
        onAccent = text(\.textOnAccent)
        card = shadesCard
            ? AnyShapeStyle(LinearGradient(
                colors: [color(.card), color(.cardEnd)], startPoint: .topLeading, endPoint: .bottomTrailing))
            : AnyShapeStyle(color(.card).gradient)
        onCard = text(\.textOnCard)
        background = color(.background, else: .systemGroupedBackground)
        surface = color(.surface, else: .secondarySystemGroupedBackground)
        setsBackground = [light.background, light.surface, dark.background, dark.surface].contains { $0 != nil }
        positive = color(.positive, else: .systemGreen)
        warning = color(.warning, else: .systemOrange)
        negative = color(.negative, else: .systemRed)
    }
}

private extension UIColor {
    convenience init?(hex: String?) {
        guard let rgb = hex.flatMap(RGB.init(hex:)) else { return nil }
        self.init(rgb)
    }

    convenience init(_ rgb: RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}

extension Color {
    init(_ rgb: RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

/// A form on the theme's page, with the theme's rows.
struct ThemedForm<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Form { Group { content }.themedRows() }.themedPage()
    }
}

/// A list on the theme's page, with the theme's rows.
struct ThemedList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        List { Group { content }.themedRows() }.themedPage()
    }
}

extension View {
    /// The theme's page behind a list or form. A theme that follows iOS leaves both as they are.
    func themedPage() -> some View {
        let palette = ThemeStore.shared.palette
        return scrollContentBackground(palette.setsBackground ? .hidden : .automatic)
            .background(palette.setsBackground ? palette.background : Color.clear)
    }

    /// The theme's rows, for the content of a list or form.
    func themedRows() -> some View {
        let palette = ThemeStore.shared.palette
        return listRowBackground(palette.setsBackground ? palette.surface : nil)
    }
}

struct MoneyText: View {
    let value: Int
    var currency = ""
    /// Transaction amounts show income in green.
    var positiveColor = Color.primary
    var negativeColor = ActualTheme.negative
    var body: some View {
        Text(Money.formatted(value, currency: currency))
            .monospacedDigit()
            .foregroundStyle(value < 0 ? negativeColor : value > 0 ? positiveColor : Color.primary)
    }
}

extension MoneyText {
    /// A transaction amount as Actual's registers show it: income in green, spending in the
    /// text color, so red stays reserved for overspending.
    static func transaction(_ value: Int, currency: String) -> MoneyText {
        MoneyText(value: value, currency: currency, positiveColor: ActualTheme.positive, negativeColor: .primary)
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
            if selected { Image(systemName: "checkmark").foregroundStyle(ActualTheme.accent) }
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
