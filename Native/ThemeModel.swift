import Foundation

/// An sRGB color, for reading theme colors and checking their contrast.
struct RGB: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let white = RGB(red: 1, green: 1, blue: 1)
    static let black = RGB(red: 0, green: 0, blue: 0)

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// A #RRGGBB color.
    init?(hex: String) {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    var hex: String {
        let parts = [red, green, blue].map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
    }

    /// WCAG relative luminance.
    var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, from 1 to 21.
    func contrast(with other: RGB) -> Double {
        let (lighter, darker) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// This color, darkened only as much as white text on it needs to reach the contrast ratio.
    func darkened(forWhiteText ratio: Double) -> RGB {
        var scale = 1.0
        func scaled() -> RGB { RGB(red: red * scale, green: green * scale, blue: blue * scale) }
        while scale > 0, RGB.white.contrast(with: scaled()) < ratio { scale -= 0.01 }
        return scaled()
    }

    /// White or black, whichever reads better on every one of these colors.
    static func text(on colors: [RGB]) -> RGB {
        func worst(_ text: RGB) -> Double { colors.map { text.contrast(with: $0) }.min() ?? 1 }
        return worst(.white) >= worst(.black) ? .white : .black
    }
}

/// What a theme color is used for.
enum ThemeRole: String, CaseIterable, Sendable {
    case accent, card, cardEnd, background, surface, positive, warning, negative
}

/// A theme's colors for one appearance, as #RRGGBB. A missing color follows iOS.
struct ThemeColors: Codable, Equatable, Sendable {
    /// Buttons, links, selection, and the main chart series.
    var accent: String
    /// The budget's summary card. With `cardEnd`, it shades from one to the other.
    var card: String
    var cardEnd: String?
    /// The page behind rows and cards.
    var background: String?
    /// Rows and cards.
    var surface: String?
    /// Income and funded balances.
    var positive: String?
    /// Underfunded balances and what is due.
    var warning: String?
    /// Overspending and errors.
    var negative: String?

    subscript(role: ThemeRole) -> String? {
        get {
            switch role {
            case .accent: accent
            case .card: card
            case .cardEnd: cardEnd
            case .background: background
            case .surface: surface
            case .positive: positive
            case .warning: warning
            case .negative: negative
            }
        }
        set {
            switch role {
            case .accent: accent = newValue ?? accent
            case .card: card = newValue ?? card
            case .cardEnd: cardEnd = newValue
            case .background: background = newValue
            case .surface: surface = newValue
            case .positive: positive = newValue
            case .warning: warning = newValue
            case .negative: negative = newValue
            }
        }
    }

    /// These colors with iOS's own in place of missing ones, so every color can be edited.
    func filled(dark: Bool) -> ThemeColors {
        var colors = self
        colors.cardEnd = cardEnd ?? card
        colors.background = background ?? (dark ? "#000000" : "#F2F2F7")
        colors.surface = surface ?? (dark ? "#1C1C1E" : "#FFFFFF")
        colors.positive = positive ?? (dark ? "#30D158" : "#34C759")
        colors.warning = warning ?? (dark ? "#FF9F0A" : "#FF9500")
        colors.negative = negative ?? (dark ? "#FF453A" : "#FF3B30")
        return colors
    }

    /// Whether iOS's text, white in dark appearance and black in light, reads on the page and rows.
    func keepsTextLegible(dark: Bool) -> Bool {
        let text: RGB = dark ? .white : .black
        return [background, surface].compactMap { $0.flatMap(RGB.init(hex:)) }.allSatisfy { text.contrast(with: $0) >= 4.5 }
    }

    /// White or black text for the summary card.
    var textOnCard: RGB { .text(on: [card, cardEnd ?? card].compactMap(RGB.init(hex:))) }
    /// White text on the summary card tinted positive or negative reaches this, with room for its shading and dimmed labels.
    static let stateCardContrast = 5.5
    /// White or black text for filled accent shapes, such as a selected filter.
    var textOnAccent: RGB { .text(on: [accent].compactMap(RGB.init(hex:))) }
}

/// A named set of colors for light and dark appearance. The app follows the device's appearance.
struct Theme: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var light: ThemeColors
    var dark: ThemeColors

    /// The colors for one appearance.
    subscript(dark isDark: Bool) -> ThemeColors {
        get { isDark ? dark : light }
        set { if isDark { dark = newValue } else { light = newValue } }
    }
}

extension Theme {
    static let presets = [actual, sterling, payday]

    /// Actual's purple and navy, on iOS's own backgrounds and status colors.
    static let actual = Theme(
        id: "actual", name: "Actual",
        light: ThemeColors(accent: "#8719E0", card: "#1D2342"),
        // Actual's dark theme lifts the purple (purple400).
        dark: ThemeColors(accent: "#9446ED", card: "#1D2342"))

    /// Black, white, and silver. Ink on a silver page in light appearance;
    /// in dark, the summary card turns to polished silver on black.
    static let sterling = Theme(
        id: "sterling", name: "Sterling",
        light: ThemeColors(
            accent: "#15171A", card: "#30343B", cardEnd: "#0C0D10",
            background: "#E8EAED", surface: "#FFFFFF",
            positive: "#1E7A4F", warning: "#9A5B00", negative: "#B42318"),
        dark: ThemeColors(
            accent: "#D5D8DD", card: "#EEF0F3", cardEnd: "#A4AAB3",
            background: "#000000", surface: "#17181B",
            positive: "#7BD3A4", warning: "#E5B567", negative: "#FF8175"))

    /// Flamingo pink on pale aqua, with a teal-to-cobalt summary card.
    static let payday = Theme(
        id: "payday", name: "Payday",
        light: ThemeColors(
            accent: "#D6186F", card: "#00808A", cardEnd: "#2347D9",
            background: "#E9F6F8", surface: "#FFFFFF",
            positive: "#0A8554", warning: "#B85C00", negative: "#D4270F"),
        dark: ThemeColors(
            accent: "#FF70B8", card: "#0A7F86", cardEnd: "#2A44CC",
            background: "#061D27", surface: "#0E2E3B",
            positive: "#4ADE9A", warning: "#FFB84D", negative: "#FF5C3D"))
}

/// The theme in use and the themes made on this device. Like Actual's theme,
/// this is a device setting rather than part of the budget.
struct ThemeSettings: Equatable, Sendable {
    var selection = Theme.actual.id
    var custom: [Theme] = []

    var all: [Theme] { Theme.presets + custom }
    /// The theme in use; Actual's if the chosen one is gone.
    var theme: Theme { all.first { $0.id == selection } ?? .actual }

    func isCustom(_ id: String) -> Bool { custom.contains { $0.id == id } }

    /// Adds an editable copy of the theme in use, and switches to it.
    @discardableResult
    mutating func addCopy(id: String = UUID().uuidString) -> Theme {
        let source = theme
        let names = Set(all.map(\.name))
        var name = "My Theme"
        var number = 2
        while names.contains(name) {
            name = "My Theme \(number)"
            number += 1
        }
        let copy = Theme(id: id, name: name, light: source.light.filled(dark: false), dark: source.dark.filled(dark: true))
        custom.append(copy)
        selection = copy.id
        return copy
    }

    /// Saves changes to a theme made on this device.
    mutating func update(_ theme: Theme) {
        guard let index = custom.firstIndex(where: { $0.id == theme.id }) else { return }
        custom[index] = theme
    }

    /// Deletes a theme made on this device. Deleting the one in use returns to Actual's.
    mutating func delete(_ id: String) {
        custom.removeAll { $0.id == id }
        if selection == id { selection = Theme.actual.id }
    }
}

extension ThemeSettings {
    static let selectionKey = "theme.selection"
    static let customKey = "theme.custom"

    init(defaults: UserDefaults) {
        selection = defaults.string(forKey: Self.selectionKey) ?? Theme.actual.id
        custom = defaults.data(forKey: Self.customKey)
            .flatMap { try? JSONDecoder().decode([Theme].self, from: $0) } ?? []
    }

    func save(to defaults: UserDefaults) {
        defaults.set(selection, forKey: Self.selectionKey)
        defaults.set(try? JSONEncoder().encode(custom), forKey: Self.customKey)
    }
}
