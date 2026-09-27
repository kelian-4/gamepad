import SwiftUI

struct PadView: View {
    @EnvironmentObject var state: GamepadState

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                mainControls
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 20)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    private var topBar: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusText)
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))

            Spacer()

            HStack(spacing: 12) {
                SmallButtonView(label: "SELECT", buttonName: "select") { pressed in
                    state.connection.sendButton(name: "select", pressed: pressed)
                }
                SmallButtonView(label: "START", buttonName: "start") { pressed in
                    state.connection.sendButton(name: "start", pressed: pressed)
                }
            }

            Spacer()

            Button {
                state.disconnect()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.top, 8)
    }

    private var mainControls: some View {
        VStack(spacing: 28) {
            HStack {
                ShoulderButtonView(label: "L1", buttonName: "l1") { pressed in
                    state.connection.sendButton(name: "l1", pressed: pressed)
                }
                Spacer()
                ShoulderButtonView(label: "R1", buttonName: "r1") { pressed in
                    state.connection.sendButton(name: "r1", pressed: pressed)
                }
            }

            HStack {
                VirtualStickView(stickName: "left") { x, y in
                    state.connection.sendStick(name: "left", x: x, y: y)
                }

                Spacer()

                abxyCluster
            }
        }
    }

    private var abxyCluster: some View {
        VStack(spacing: 4) {
            GamepadButtonView(label: "Y", buttonName: "y") { pressed in
                state.connection.sendButton(name: "y", pressed: pressed)
            }
            HStack(spacing: 4) {
                GamepadButtonView(label: "X", buttonName: "x") { pressed in
                    state.connection.sendButton(name: "x", pressed: pressed)
                }
                Spacer().frame(width: 60)
                GamepadButtonView(label: "B", buttonName: "b") { pressed in
                    state.connection.sendButton(name: "b", pressed: pressed)
                }
            }
            GamepadButtonView(label: "A", buttonName: "a") { pressed in
                state.connection.sendButton(name: "a", pressed: pressed)
            }
        }
    }

    private var statusColor: Color {
        switch state.connection.status {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    private var statusText: String {
        switch state.connection.status {
        case .connected: return "Connecté"
        case .connecting: return "Connexion…"
        case .failed(let message): return message
        case .disconnected: return "Déconnecté"
        }
    }
}

#Preview {
    PadView().environmentObject(GamepadState())
}
