import SwiftUI

@main
struct KiCadQuickLookApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 640, minHeight: 480)
        }
        .windowResizability(.contentMinSize)
    }
}
