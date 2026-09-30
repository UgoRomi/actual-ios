import SwiftUI
import UIKit

/// Amount entry whose keyboard is a calculator keypad, as in Actual's mobile calculator.
/// Enter a number or a calculation such as 20+5; = and leaving the field show its result.
struct AmountField: View {
    let label: String
    @Binding var text: String
    var placeholder = Money.editable(0)
    var large = false
    var focusesOnAppear = false
    var textColor = UIColor.label

    var body: some View {
        let descender = AmountTextField.font(large: large).descender
        Representable(label: label, text: $text, placeholder: placeholder, large: large,
                      focusesOnAppear: focusesOnAppear, textColor: textColor)
            // Align with neighboring text by the field's baseline rather than its bottom.
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + descender }
    }

    private struct Representable: UIViewRepresentable {
        let label: String
        @Binding var text: String
        let placeholder: String
        let large: Bool
        let focusesOnAppear: Bool
        let textColor: UIColor

        func makeUIView(context: Context) -> AmountTextField {
            let field = AmountTextField(focusesOnAppear: focusesOnAppear)
            field.font = AmountTextField.font(large: large)
            field.placeholder = placeholder
            field.accessibilityLabel = label
            field.delegate = context.coordinator
            field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return field
        }

        func updateUIView(_ field: AmountTextField, context: Context) {
            context.coordinator.text = $text
            if field.text != text { field.text = text }
            field.isEnabled = context.environment.isEnabled
            field.textColor = field.isEnabled ? textColor : .secondaryLabel
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView field: AmountTextField, context: Context) -> CGSize? {
            let size = field.intrinsicContentSize
            return CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? size.width, height: size.height)
        }

        func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

        final class Coordinator: NSObject, UITextFieldDelegate {
            var text: Binding<String>

            init(text: Binding<String>) { self.text = text }

            @objc func changed(_ field: UITextField) {
                let value = field.text ?? ""
                if text.wrappedValue != value { text.wrappedValue = value }
            }

            func textFieldDidEndEditing(_ field: UITextField) {
                (field as? AmountTextField)?.showResult()
            }
        }
    }
}

/// A text field that edits amounts with `CalculatorKeypad`.
final class AmountTextField: UITextField {
    private var focusesOnAppear: Bool

    init(focusesOnAppear: Bool) {
        self.focusesOnAppear = focusesOnAppear
        super.init(frame: .zero)
        adjustsFontForContentSizeCategory = true
        autocorrectionType = .no
        spellCheckingType = .no
        smartInsertDeleteType = .no
        inputView = CalculatorKeypad(field: self)
        // No shortcuts bar above the keypad on iPad.
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Rounded large title or body text, with monospaced digits.
    static func font(large: Bool) -> UIFont {
        let style: UIFont.TextStyle = large ? .largeTitle : .body
        let base = UIFontDescriptor.preferredFontDescriptor(
            withTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        var descriptor = base
        if large, let rounded = base.withDesign(.rounded) {
            descriptor = rounded.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]])
        }
        descriptor = descriptor.addingAttributes([.featureSettings: [[
            UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
            UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
        ]]])
        return UIFontMetrics(forTextStyle: style).scaledFont(for: UIFont(descriptor: descriptor, size: base.pointSize))
    }

    /// Replace a valid entry with its result, as Actual's = key and leaving its field do.
    func showResult() {
        guard let text, let value = Money.parse(text) else { return }
        replace(with: Money.editable(value))
    }

    func replace(with value: String) {
        guard text != value else { return }
        text = value
        sendActions(for: .editingChanged)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard focusesOnAppear, window != nil else { return }
        focusesOnAppear = false
        // Once the presenting sheet is in place.
        Task { becomeFirstResponder() }
    }
}

/// Actual's calculator keypad (`CalculatorButtons`), as the keyboard of an amount field.
final class CalculatorKeypad: UIInputView, UIInputViewAudioFeedback {
    private enum Style { case character, function, primary }

    private weak var field: AmountTextField?
    var enableInputClicksWhenVisible: Bool { true }

    init(field: AmountTextField) {
        self.field = field
        let keys: CGFloat = 5 * 46 + 4 * 6
        // The system adds the home indicator's inset below this height.
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: keys + 14), inputViewStyle: .keyboard)
        accessibilityIdentifier = "calculator-keypad"
        let formatter = NumberFormatter()
        // The budget's number format decides the decimal key, as it decides how amounts read.
        formatter.locale = Money.locale
        let digit = { (value: Int) in self.insertKey(formatter.string(from: value as NSNumber) ?? String(value)) }
        let rows = [
            [key("AC", label: "Clear", style: .function) { $0.replace(with: "") },
             insertKey("(", label: "Open parenthesis", style: .function),
             insertKey(")", label: "Close parenthesis", style: .function),
             insertKey("÷", label: "Divide", style: .function)],
            [digit(7), digit(8), digit(9), insertKey("×", label: "Multiply", style: .function)],
            [digit(4), digit(5), digit(6), insertKey("−", label: "Minus", style: .function)],
            [digit(1), digit(2), digit(3), insertKey("+", label: "Plus", style: .function)],
            [key(image: "delete.left", label: "Delete", style: .function) { $0.deleteBackward() },
             digit(0), insertKey(formatter.decimalSeparator ?? "."),
             key("=", label: "Equals", style: .primary) { $0.showResult() }],
        ]
        let grid = UIStackView(arrangedSubviews: rows.map { row in
            let stack = UIStackView(arrangedSubviews: row)
            stack.distribution = .fillEqually
            stack.spacing = 6
            return stack
        })
        grid.axis = .vertical
        grid.distribution = .fillEqually
        grid.spacing = 6
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        let fullWidth = grid.widthAnchor.constraint(equalTo: safeAreaLayoutGuide.widthAnchor, constant: -16)
        let fullHeight = grid.heightAnchor.constraint(equalToConstant: keys)
        fullWidth.priority = .defaultHigh
        fullHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor, constant: -4),
            grid.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            grid.widthAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.widthAnchor, constant: -16),
            grid.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
            fullWidth,
            fullHeight,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func insertKey(_ text: String, label: String? = nil, style: Style = .character) -> UIButton {
        key(text, label: label, style: style) { $0.insertText(text) }
    }

    private func key(_ title: String? = nil, image: String? = nil, label: String?, style: Style,
                     action: @escaping (AmountTextField) -> Void) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        if let title {
            let size: CGFloat = title.count > 1 ? 18 : 25
            configuration.attributedTitle = AttributedString(
                title, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: size, weight: style == .character ? .regular : .medium)]))
        }
        configuration.image = image.flatMap { UIImage(systemName: $0) }
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        configuration.baseForegroundColor = style == .primary ? UIColor(ActualTheme.onAccent) : .label
        configuration.baseBackgroundColor = switch style {
        case .character: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.3) : .white }
        case .function: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.1) }
        case .primary: UIColor(ActualTheme.accent)
        }
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 10
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            UIDevice.current.playInputClick()
            guard let field = self?.field else { return }
            action(field)
            field.sendActions(for: .editingChanged)
        })
        button.accessibilityLabel = label
        button.accessibilityTraits.insert(.keyboardKey)
        return button
    }
}
