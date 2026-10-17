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

    @Published var streamSecret: String? {
        didSet { UserDefaults.standard.set(streamSecret, forKey: Self.secretKey) }
    }

    let connection = GamepadConnection()

    private static let hostKey = "gamepad.server.host"
    private static let portKey = "gamepad.server.port"
    private static let secretKey = "gamepad.stream.secret"

    init() {
        self.serverHost = UserDefaults.standard.string(forKey: Self.hostKey) ?? ""
        self.serverPort = UserDefaults.standard.string(forKey: Self.portKey) ?? "8765"
        self.streamSecret = UserDefaults.standard.string(forKey: Self.secretKey)
    }

    func connect() {
        guard let port = UInt16(serverPort), !serverHost.isEmpty else { return }
        connection.connect(host: serverHost, port: port, streamSecret: streamSecret)
    }

    func disconnect() {
        connection.disconnect()
    }
}
