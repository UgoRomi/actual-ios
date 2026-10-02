import Foundation

/// Theme colors, presets' legibility, and the themes made on this device.
@main struct Themes {
    static func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
        precondition(condition, message(), line: line)
    }

    static func main() {
        // Colors read and write as #RRGGBB.
        expect(RGB(hex: "#8719E0")?.hex == "#8719E0", "hex round trip")
        expect(RGB(hex: "8719E0") == nil && RGB(hex: "#8719E") == nil && RGB(hex: "#GGGGGG") == nil, "invalid hex")
        expect(abs(RGB.white.contrast(with: .black) - 21) < 0.001, "black on white is 21:1")
        expect(RGB.text(on: [RGB(hex: "#1D2342")!]) == .white, "white text on navy")
        expect(RGB.text(on: [RGB(hex: "#EEF0F3")!, RGB(hex: "#A4AAB3")!]) == .black, "black text on silver")
        // The summary card tinted positive or negative darkens only as much as white text needs.
        for hex in ["#34C759", "#FF3B30", "#FFFF00", "#FFFFFF", "#1D2342", "#000000"] {
            let color = RGB(hex: hex)!, card = color.darkened(forWhiteText: ThemeColors.stateCardContrast)
            expect(RGB.white.contrast(with: card) >= ThemeColors.stateCardContrast, "white on \(hex) tinted card")
            if RGB.white.contrast(with: color) >= ThemeColors.stateCardContrast { expect(card == color, "\(hex) kept as is") }
        }
        print("PASS: colors")

        // Every preset keeps its colors legible where the app draws them.
        let ids = Theme.presets.map(\.id)
        expect(Set(ids).count == ids.count && ids.first == Theme.actual.id, "preset identifiers")
        for theme in Theme.presets {
            for dark in [false, true] {
                let colors = theme[dark: dark]
                let name = "\(theme.name) \(dark ? "dark" : "light")"
                for role in ThemeRole.allCases {
                    if let hex = colors[role] { expect(RGB(hex: hex) != nil, "\(name) \(role.rawValue) is not a color") }
                }
                let accent = RGB(hex: colors.accent)!
                expect(colors.textOnAccent.contrast(with: accent) >= 4.5, "\(name): text on accent")
                for hex in [colors.card, colors.cardEnd ?? colors.card] {
                    let contrast = colors.textOnCard.contrast(with: RGB(hex: hex)!)
                    expect(contrast >= 4.5, "\(name): text on card \(hex) is \(contrast)")
                }
                // Where a preset follows iOS, iOS keeps its own colors legible.
                guard let surface = colors.surface.flatMap(RGB.init(hex:)),
                      let background = colors.background.flatMap(RGB.init(hex:)) else { continue }
                let text: RGB = dark ? .white : .black
                expect(text.contrast(with: surface) >= 7 && text.contrast(with: background) >= 7, "\(name): text")
                expect(colors.keepsTextLegible(dark: dark) && !colors.keepsTextLegible(dark: !dark), "\(name): legibility check")
                for role in [ThemeRole.accent, .positive, .warning, .negative] {
                    let contrast = RGB(hex: colors[role]!)!.contrast(with: surface)
                    expect(contrast >= 4.5, "\(name): \(role.rawValue) on rows is \(contrast)")
                }
                expect(accent.contrast(with: background) >= 4.5, "\(name): accent on the page")
            }
        }
        print("PASS: presets")

        // A new theme copies the one in use, with every color filled in.
        var settings = ThemeSettings()
        expect(settings.theme == .actual, "Actual by default")
        let copy = settings.addCopy(id: "one")
        expect(copy.name == "My Theme" && settings.selection == "one" && settings.theme == copy, "copy is in use")
        expect(copy.light.accent == Theme.actual.light.accent && copy.dark.accent == Theme.actual.dark.accent, "copies colors")
        for role in ThemeRole.allCases {
            expect(copy.light[role] != nil && copy.dark[role] != nil, "copy fills \(role.rawValue)")
        }
        expect(copy.light.background == "#F2F2F7" && copy.dark.background == "#000000", "iOS backgrounds")
        expect(settings.addCopy(id: "two").name == "My Theme 2", "unique names")

        var edited = copy
        edited.name = "Mine"
        edited.light[.accent] = "#112233"
        edited.light[.accent] = nil
        edited[dark: true].surface = "#202020"
        settings.update(edited)
        settings.selection = "one"
        expect(settings.theme.name == "Mine" && settings.theme.light.accent == "#112233", "edits save; accent stays set")
        expect(settings.theme.dark.surface == "#202020" && settings.theme.light.surface == "#FFFFFF", "appearances are edited apart")
        expect(Theme.actual.light.keepsTextLegible(dark: false), "a theme that follows iOS stays legible")
        var preset = Theme.sterling
        preset.name = "Changed"
        settings.update(preset)
        expect(settings.all.first { $0.id == "sterling" } == .sterling, "presets cannot be edited")

        // Saved and read back.
        let suite = "themes-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        expect(ThemeSettings(defaults: defaults) == ThemeSettings(), "defaults start with Actual")
        settings.save(to: defaults)
        expect(ThemeSettings(defaults: defaults) == settings, "settings round trip")

        settings.delete("two")
        expect(settings.selection == "one" && settings.custom.count == 1, "deleting another theme keeps the one in use")
        settings.delete("one")
        expect(settings.theme == .actual && settings.custom.isEmpty, "deleting the theme in use returns to Actual")
        settings.selection = "missing"
        expect(settings.theme == .actual, "unknown selection falls back to Actual")
        print("PASS: settings")
    }
}
