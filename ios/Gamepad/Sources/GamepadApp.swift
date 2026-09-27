import SwiftUI

@main
struct GamepadApp: App {
    @StateObject private var state = GamepadState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
        }
    }
}
