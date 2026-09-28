import SwiftUI

struct ConnectView: View {
    @EnvironmentObject var state: GamepadState

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 44))
                .foregroundColor(.accentColor)

            Text("Manette virtuelle")
                .font(.title2.bold())

            VStack(spacing: 10) {
                TextField("Adresse IP (ex: 192.168.1.42)", text: $state.serverHost)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.decimalPad)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                TextField("Port", text: $state.serverPort)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
            }
            .frame(maxWidth: 280)

            statusLabel

            Button {
                state.connect()
            } label: {
                Text("Se connecter")
                    .font(.headline)
                    .frame(maxWidth: 280)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.serverHost.isEmpty)
        }
        .padding()
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch state.connection.status {
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
    ConnectView().environmentObject(GamepadState())
}
