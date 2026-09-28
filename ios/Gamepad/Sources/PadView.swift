import SwiftUI

struct PadView: View {
    @EnvironmentObject var state: GamepadState

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                shoulders
                Spacer(minLength: 4)
                mainLayout
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    // MARK: - Barre du haut

    private var topBar: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            Text(statusText)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.55))
            Spacer()
            Button {
                state.disconnect()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.top, 6)
    }

    // MARK: - LT/LB et RT/RB

    private var shoulders: some View {
        HStack(alignment: .top) {
            VStack(spacing: 6) {
                AnalogTriggerView(label: "LT") { v in
                    state.connection.sendTrigger(name: "l2", value: v)
                }
                ShoulderButtonView(label: "LB", buttonName: "l1") { pressed in
                    state.connection.sendButton(name: "l1", pressed: pressed)
                }
            }
            Spacer()
            VStack(spacing: 6) {
                AnalogTriggerView(label: "RT") { v in
                    state.connection.sendTrigger(name: "r2", value: v)
                }
                ShoulderButtonView(label: "RB", buttonName: "r1") { pressed in
                    state.connection.sendButton(name: "r1", pressed: pressed)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Corps de la manette (disposition Xbox)

    private var mainLayout: some View {
        HStack(alignment: .center) {
            // Colonne gauche : stick gauche en haut, croix en bas
            VStack(spacing: 14) {
                stickWithClick(name: "left", clickName: "thumbl")
                DPadView { x, y in
                    state.connection.sendDpad(x: x, y: y)
                }
            }

            Spacer()

            // Centre : View / Xbox / Menu
            VStack(spacing: 14) {
                XboxCenterButton { pressed in
                    state.connection.sendButton(name: "mode", pressed: pressed)
                }
                HStack(spacing: 10) {
                    SmallButtonView(label: "VIEW", buttonName: "select") { pressed in
                        state.connection.sendButton(name: "select", pressed: pressed)
                    }
                    SmallButtonView(label: "MENU", buttonName: "start") { pressed in
                        state.connection.sendButton(name: "start", pressed: pressed)
                    }
                }
            }

            Spacer()

            // Colonne droite : ABXY en haut, stick droit en bas
            VStack(spacing: 14) {
                abxyCluster
                stickWithClick(name: "right", clickName: "thumbr")
            }
        }
    }

    private func stickWithClick(name: String, clickName: String) -> some View {
        ZStack(alignment: .bottomTrailing) {
            VirtualStickView(stickName: name) { x, y in
                state.connection.sendStick(name: name, x: x, y: y)
            }
            StickClickButton { pressed in
                state.connection.sendButton(name: clickName, pressed: pressed)
            }
            .offset(x: 6, y: 6)
        }
    }

    private var abxyCluster: some View {
        VStack(spacing: 2) {
            GamepadButtonView(label: "Y", buttonName: "y") { pressed in
                state.connection.sendButton(name: "y", pressed: pressed)
            }
            HStack(spacing: 2) {
                GamepadButtonView(label: "X", buttonName: "x") { pressed in
                    state.connection.sendButton(name: "x", pressed: pressed)
                }
                Spacer().frame(width: 56)
                GamepadButtonView(label: "B", buttonName: "b") { pressed in
                    state.connection.sendButton(name: "b", pressed: pressed)
                }
            }
            GamepadButtonView(label: "A", buttonName: "a") { pressed in
                state.connection.sendButton(name: "a", pressed: pressed)
            }
        }
    }

    // MARK: - Statut

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
