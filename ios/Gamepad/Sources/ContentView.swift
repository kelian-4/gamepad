import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: GamepadState

    var body: some View {
        Root(connection: state.connection)
            .preferredColorScheme(.dark)
    }
}

private struct Root: View {
    @ObservedObject var connection: GamepadConnection

    var body: some View {
        Group {
            if showPad {
                EdgeGestureDeferringHost {
                    PadView(connection: connection)
                }
            } else {
                ConnectView(connection: connection)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: connection.status)
    }

    private var showPad: Bool {
        switch connection.status {
        case .connected, .reconnecting: return true
        case .connecting, .failed, .disconnected: return false
        }
    }
}

#Preview {
    ContentView().environmentObject(GamepadState())
}
