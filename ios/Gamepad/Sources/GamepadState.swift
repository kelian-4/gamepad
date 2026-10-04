import Foundation
import Combine

@MainActor
final class GamepadState: ObservableObject {
    @Published var serverHost: String {
        didSet { UserDefaults.standard.set(serverHost, forKey: Self.hostKey) }
    }
    @Published var serverPort: String {
        didSet { UserDefaults.standard.set(serverPort, forKey: Self.portKey) }
    }

    let connection = GamepadConnection()

    private static let hostKey = "gamepad.server.host"
    private static let portKey = "gamepad.server.port"

    init() {
        self.serverHost = UserDefaults.standard.string(forKey: Self.hostKey) ?? ""
        self.serverPort = UserDefaults.standard.string(forKey: Self.portKey) ?? "8765"
    }

    func connect() {
        guard let port = UInt16(serverPort), !serverHost.isEmpty else { return }
        connection.connect(host: serverHost, port: port)
    }

    func disconnect() {
        connection.disconnect()
    }
}
