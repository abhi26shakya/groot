import SwiftUI
import GrootKit

@main
struct GrootApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Groot", id: "dashboard") {
            DashboardView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 600)
                .task { await model.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        MenuBarExtra("Groot", systemImage: "sparkles") {
            MenuBarView()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}
