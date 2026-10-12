import SwiftUI
import UIKit

/// Floats chips over the app, sheets included, while a saved transaction's balance changes show.
/// The chips take no touches, so the app stays usable beneath them.
struct BalanceFeedbackWindow: UIViewRepresentable {
    let model: AppModel
    var isShowing: Bool

    func makeUIView(context: Context) -> Anchor { Anchor(model: model) }

    func updateUIView(_ anchor: Anchor, context: Context) { anchor.isShowing = isShowing }

    /// Adds the overlay window to the scene of the window it is placed in.
    final class Anchor: UIView {
        private let model: AppModel
        private var overlay: UIWindow?
        /// The window stays hidden between feedbacks, so it never affects the app around it.
        var isShowing = false { didSet { overlay?.isHidden = !isShowing } }

        init(model: AppModel) {
            self.model = model
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard overlay == nil, let scene = window?.windowScene else { return }
            let overlay = PassthroughWindow(windowScene: scene)
            let host = UIHostingController(rootView: BalanceFeedbackView().environment(model))
            host.view.backgroundColor = .clear
            overlay.rootViewController = host
            overlay.windowLevel = .normal + 1
            overlay.isHidden = !isShowing
            self.overlay = overlay
        }
    }

    private final class PassthroughWindow: UIWindow {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }
}

/// One chip per category: its balance before the transaction, counting to its balance after.
struct BalanceFeedbackView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: BalanceFeedback?
    @State private var settled = false

    var body: some View {
        VStack(spacing: 8) {
            if let shown {
                ForEach(shown.changes) { change in
                    BalanceChip(change: change, settled: settled)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: model.balanceFeedback?.id) { await present(model.balanceFeedback) }
    }

    private func present(_ feedback: BalanceFeedback?) async {
        guard let feedback else { return }
        settled = false
        withAnimation(.spring(duration: 0.35)) { shown = feedback }
        AccessibilityNotification.Announcement(feedback.changes.map {
            "\($0.name): \(Money.formatted($0.after, currency: model.currency))"
        }.joined(separator: ", ")).post()
        // A newer transaction's feedback cancels this one and takes its place.
        do {
            try await Task.sleep(for: .milliseconds(450))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.7)) { settled = true }
            try await Task.sleep(for: .milliseconds(1700))
            withAnimation(.easeIn(duration: 0.25)) { shown = nil }
            try await Task.sleep(for: .milliseconds(300))
        } catch { return }
        if model.balanceFeedback?.id == feedback.id { model.balanceFeedback = nil }
    }
}

private struct BalanceChip: View {
    @Environment(AppModel.self) private var model
    let change: CategoryBalanceChange
    let settled: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(change.name).font(.subheadline.weight(.medium)).lineLimit(1)
            Spacer(minLength: 0)
            CountingAmount(value: Double(settled ? change.after : change.before), currency: model.currency)
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassEffect(in: .capsule)
    }
}

/// An amount that counts from one value to the next as it animates. As on the budget, overspending is red.
private struct CountingAmount: View, Animatable {
    var value: Double
    let currency: String

    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        let cents = Int(value.rounded())
        Text(Money.formatted(cents, currency: currency))
            .foregroundStyle(cents < 0 ? ActualTheme.negative : Color.primary)
    }
}
