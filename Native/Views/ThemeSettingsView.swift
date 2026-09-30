import SwiftUI

/// Chooses the app's theme, and lists the themes made on this device.
struct ThemesView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var edited: String?
    private var store: ThemeStore { .shared }

    var body: some View {
        ThemedList {
            Section {
                ForEach(Theme.presets) { row($0) }
            }
            Section {
                ForEach(store.settings.custom) { theme in
                    row(theme).swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { store.delete(theme.id) }
                    }
                }
                Button("New Theme", systemImage: "plus") { edited = store.addCopy().id }
            } header: { Text("Your themes") } footer: {
                Text("A new theme starts as a copy of the one in use. Themes stay on this device and follow its light or dark appearance.")
            }
        }
        .navigationTitle("Theme").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $edited) { ThemeEditor(themeID: $0) }
    }

    private func row(_ theme: Theme) -> some View {
        let selected = store.settings.selection == theme.id
        let dark = colorScheme == .dark
        return HStack(spacing: 12) {
            Button { store.select(theme.id) } label: {
                HStack(spacing: 12) {
                    ThemeSwatch(colors: theme[dark: dark].filled(dark: dark))
                    Text(theme.name).foregroundStyle(Color.primary)
                    Spacer()
                    if selected { Image(systemName: "checkmark").foregroundStyle(ActualTheme.accent) }
                }.contentShape(Rectangle())
            }
            .accessibilityAddTraits(selected ? .isSelected : [])
            if store.settings.isCustom(theme.id) {
                Button("Edit \(theme.name)", systemImage: "slider.horizontal.3") { edited = theme.id }
                    .labelStyle(.iconOnly)
            }
        }
        // Each button in the row takes its own taps.
        .buttonStyle(.borderless)
    }
}

/// A theme in miniature: its page, summary card, and a row with its amount colors and accent.
private struct ThemeSwatch: View {
    let colors: ThemeColors

    var body: some View {
        let palette = ThemePalette(colors)
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 4).fill(palette.card).frame(height: 14)
            HStack(spacing: 3) {
                ForEach([palette.positive, palette.warning, palette.negative], id: \.self) {
                    Circle().fill($0).frame(width: 5, height: 5)
                }
                Spacer(minLength: 0)
                Capsule().fill(palette.accent).frame(width: 14, height: 5)
            }
            .padding(.horizontal, 5).frame(height: 14)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(5).frame(width: 60)
        .background(palette.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.12)) }
        .accessibilityHidden(true)
    }
}

/// Edits a theme made on this device. Changes show across the app as they are made.
private struct ThemeEditor: View {
    let themeID: String
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    /// The appearance whose colors are being edited; the device's until one is chosen.
    @State private var chosenAppearance: Bool?
    @State private var confirmsDelete = false
    private var store: ThemeStore { .shared }

    private var theme: Theme? { store.settings.custom.first { $0.id == themeID } }
    private var dark: Bool { chosenAppearance ?? (colorScheme == .dark) }

    var body: some View {
        ThemedForm {
            if let theme {
                let colors = theme[dark: dark]
                Section {
                    ThemePreview(colors: colors.filled(dark: dark), dark: dark, currency: model.currency)
                }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                Section {
                    LabeledContent("Name") { TextField("Name", text: $name).multilineTextAlignment(.trailing) }
                    Picker("Appearance", selection: Binding(get: { dark }, set: { chosenAppearance = $0 })) {
                        Text("Light").tag(false)
                        Text("Dark").tag(true)
                    }.pickerStyle(.segmented)
                } footer: {
                    Text("A theme has its own colors for light and dark appearance.")
                }
                Section {
                    picker("Accent", .accent)
                    picker("Page", .background)
                    picker("Rows and cards", .surface)
                    if !colors.keepsTextLegible(dark: dark) {
                        Label("Text is \(dark ? "white" : "black") in \(dark ? "dark" : "light") appearance, so it may be hard to read on these colors.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("Interface") }
                Section {
                    picker("Start", .card)
                    picker("End", .cardEnd)
                } header: { Text("Summary card") }
                Section {
                    picker("Positive", .positive)
                    picker("Warning", .warning)
                    picker("Negative", .negative)
                } header: { Text("Amounts") } footer: {
                    Text("Income and funded categories are positive. Underfunded categories and schedules that are due are warnings. Overspending and errors are negative.")
                }
                Section {
                    Button("Delete Theme", role: .destructive) { confirmsDelete = true }
                        .confirmationDialog("Delete “\(theme.name)”?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                            Button("Delete Theme", role: .destructive) {
                                store.delete(themeID)
                                dismiss()
                            }
                            Button("Cancel", role: .cancel) { }
                        }
                }
            }
        }
        .navigationTitle(theme?.name ?? "Theme").navigationBarTitleDisplayMode(.inline)
        .onAppear { name = theme?.name ?? "" }
        .onChange(of: name) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, var theme else { return }
            theme.name = trimmed
            store.update(theme)
        }
    }

    private func picker(_ title: String, _ role: ThemeRole) -> some View {
        ColorPicker(title, selection: Binding(
            get: { theme?[dark: dark][role].flatMap(RGB.init(hex:)).map(Color.init) ?? .clear },
            set: { color in
                guard var theme else { return }
                theme[dark: dark][role] = color.hex
                store.update(theme)
            }), supportsOpacity: false)
    }
}

/// A budget in miniature, in one appearance of a theme.
private struct ThemePreview: View {
    let colors: ThemeColors
    let dark: Bool
    let currency: String

    var body: some View {
        let palette = ThemePalette(colors)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Available to budget", systemImage: "circle.dotted")
                    .font(.subheadline.weight(.medium)).foregroundStyle(palette.onCard.opacity(0.8))
                Spacer(minLength: 8)
                Text(Money.formatted(125_000, currency: currency))
                    .font(.system(.title3, design: .rounded, weight: .bold)).monospacedDigit()
                    .foregroundStyle(palette.onCard)
            }
            .padding(14).background(palette.card, in: RoundedRectangle(cornerRadius: 18))
            HStack(spacing: 8) {
                chip("All", foreground: palette.onAccent, background: palette.accent)
                chip("Overspent", foreground: .primary, background: palette.surface)
            }
            VStack(spacing: 0) {
                row("Groceries", -3_210, palette.negative)
                Divider().padding(.leading, 14)
                row("Dining out", 1_840, palette.warning)
                Divider().padding(.leading, 14)
                row("Fuel", 4_200, palette.positive)
            }.background(palette.surface, in: RoundedRectangle(cornerRadius: 16))
        }
        .lineLimit(1)
        .padding(14)
        .background(palette.background, in: RoundedRectangle(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(Color.primary.opacity(0.12)) }
        .environment(\.colorScheme, dark ? .dark : .light)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview in \(dark ? "dark" : "light") appearance")
    }

    private func chip(_ title: String, foreground: Color, background: Color) -> some View {
        Text(title).font(.subheadline.weight(.medium)).foregroundStyle(foreground)
            .padding(.horizontal, 12).padding(.vertical, 6).background(background, in: Capsule())
    }

    private func row(_ name: String, _ balance: Int, _ color: Color) -> some View {
        HStack {
            Text(name).foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            Text(Money.formatted(balance, currency: currency))
                .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(color)
                .padding(.horizontal, 8).padding(.vertical, 3).background(color.opacity(0.14), in: Capsule())
        }.padding(.horizontal, 14).padding(.vertical, 9)
    }
}
