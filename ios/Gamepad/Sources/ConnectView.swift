import SwiftUI

struct ConnectView: View {
    @EnvironmentObject var state: GamepadState
    @ObservedObject var connection: GamepadConnection

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)

            Text("Manette virtuelle")
                .font(.title2.bold())

            VStack(spacing: 10) {
                TextField("Adresse IP (ex: 192.168.1.42)", text: $state.serverHost)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                TextField("Port", text: $state.serverPort)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
            }
            .frame(maxWidth: 280)

            statusLabel

            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                state.connect()
            } label: {
                Text("Se connecter")
                    .font(.headline)
                    .frame(maxWidth: 280)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.serverHost.isEmpty)

            if !connection.events.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(connection.events.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .frame(maxWidth: 320, alignment: .leading)
            }
        }
        .padding()
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch connection.status {
        case .connecting:
            Label("Connexion…", systemImage: "ellipsis.circle")
                .foregroundColor(.orange)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundColor(.red)
                .font(.caption)
        default:
            EmptyView()
        }
    }
}

#Preview {
    let s = GamepadState()
    return ConnectView(connection: s.connection).environmentObject(s)
}
