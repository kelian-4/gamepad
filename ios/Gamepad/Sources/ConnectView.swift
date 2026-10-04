import SwiftUI

struct ConnectView: View {
    @EnvironmentObject var state: GamepadState
    @ObservedObject var connection: GamepadConnection
    @StateObject private var discovery = ServerDiscovery()

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

            Button {
                discovery.start()
            } label: {
                Label(discovery.isSearching ? "Recherche…" : "Rechercher automatiquement", systemImage: "wifi")
                    .font(.footnote)
            }
            .disabled(discovery.isSearching)

            if !discovery.results.isEmpty {
                VStack(spacing: 6) {
                    ForEach(discovery.results) { found in
                        Button {
                            state.serverHost = found.host
                            state.serverPort = String(found.port)
                            discovery.stop()
                        } label: {
                            HStack {
                                Image(systemName: "server.rack")
                                Text("\(found.name) — \(found.host):\(found.port)")
                                    .font(.caption)
                            }
                        }
                    }
                }
                .frame(maxWidth: 280)
            } else if discovery.permissionSuspected {
                VStack(spacing: 4) {
                    Text("Aucun serveur trouvé. L'app n'a peut-être pas la permission d'accéder au réseau local.")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                    Text("Vérifie Réglages > Gamepad > Réseau local, ou utilise l'IP manuellement.")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 280)
            } else if discovery.searchedWithNoResult {
                Text("Aucun serveur trouvé sur le réseau local. Vérifie que le serveur est lancé et que le téléphone est sur le même Wi-Fi.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }

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
        }
        .padding()
        .onDisappear {
            discovery.stop()
        }
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
