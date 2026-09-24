import SwiftUI

@main
struct ActualNativeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(ActualTheme.purple)
                .task { await model.activate() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.enteredBackground() }
                    else if phase == .active { Task { await model.activate() } }
                }
        }
    }
}
