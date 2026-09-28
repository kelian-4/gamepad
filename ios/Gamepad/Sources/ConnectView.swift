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

            TextField("192.168.1.42:8765", text: $state.serverAddress)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                .onSubmit { state.connect() }
                .frame(maxWidth: 280)

            Text("Le port 8765 est utilisé par défaut s'il est omis")
                .font(.caption)
                .foregroundColor(.secondary)

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
            .disabled(state.parsedAddress == nil)
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
