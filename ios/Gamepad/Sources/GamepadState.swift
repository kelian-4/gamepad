import Foundation
import Combine

@MainActor
final class GamepadState: ObservableObject {
    static let defaultPort: UInt16 = 8765

    @Published var serverAddress: String {
        didSet { UserDefaults.standard.set(serverAddress, forKey: Self.addressKey) }
    }

    let connection = GamepadConnection()

    private static let addressKey = "gamepad.server.address"

    init() {
        self.serverAddress = UserDefaults.standard.string(forKey: Self.addressKey) ?? ""
    }

    var parsedAddress: (host: String, port: UInt16)? {
        let trimmed = serverAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "ws://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
        guard let host = parts.first, !host.isEmpty else { return nil }

        if parts.count == 2 {
            guard let port = UInt16(parts[1]) else { return nil }
            return (host, port)
        }
        return (host, Self.defaultPort)
    }

    func connect() {
        guard let address = parsedAddress else { return }
        connection.connect(host: address.host, port: address.port)
    }

    func disconnect() {
        connection.disconnect()
    }
}
