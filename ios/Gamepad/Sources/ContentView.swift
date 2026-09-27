import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: GamepadState

    var body: some View {
        Group {
            if state.connection.status == .connected {
                PadView()
            } else {
                ConnectView()
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.25), value: state.connection.status)
    }
}

#Preview {
    ContentView().environmentObject(GamepadState())
}
