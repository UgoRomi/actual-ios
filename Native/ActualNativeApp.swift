import SwiftUI

@main
struct ActualNativeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        AppModel.current = model
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.activate() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        model.enteredBackground()
                        // A theme change shows on the widget once the app is left.
                        WidgetSupport.update(from: model)
                        WidgetSupport.scheduleRefresh()
                    } else if phase == .active { Task { await model.activate() } }
                }
                // The widget shows the budget as last loaded.
                .onChange(of: model.dataRevision) { WidgetSupport.update(from: model) }
                .onChange(of: model.isBudgetOpen) { WidgetSupport.update(from: model) }
        }
        // iOS wakes the app now and then to sync, so the widget and the budget stay current.
        .backgroundTask(.appRefresh(WidgetSupport.refreshTask)) {
            await MainActor.run { WidgetSupport.scheduleRefresh() }
            let model = await MainActor.run { AppModel.current }
            await model?.backgroundRefresh()
            await MainActor.run { if let model { WidgetSupport.update(from: model) } }
        }
    }
}
