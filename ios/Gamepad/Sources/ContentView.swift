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
            if connection.status == .connected {
                PadView(connection: connection)
            } else {
                ConnectView(connection: connection)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: connection.status)
    }
}

#Preview {
    ContentView().environmentObject(GamepadState())
}
