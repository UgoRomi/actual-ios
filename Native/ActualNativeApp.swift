import SwiftUI

@main
struct ActualNativeApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(ActualTheme.purple)
                .task { await model.start() }
        }
    }
}
