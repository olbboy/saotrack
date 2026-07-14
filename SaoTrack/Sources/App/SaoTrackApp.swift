import SwiftUI

@main
@MainActor
struct SaoTrackApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 860, minHeight: 620)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SetupView()
                .environment(appState)
        }
    }
}
