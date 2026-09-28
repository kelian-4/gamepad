import Foundation
import Network

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

@MainActor
final class GamepadConnection: ObservableObject {
    @Published private(set) var status: ConnectionStatus = .disconnected

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.kelian.gamepad.ws")
    private var host: String = ""
    private var port: UInt16 = 8765
    private var reconnectTask: Task<Void, Never>?
    private var shouldStayConnected = false

    func connect(host: String, port: UInt16) {
        self.host = host
        self.port = port
        shouldStayConnected = true
        startConnection()
    }

    func disconnect() {
        shouldStayConnected = false
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.cancel()
        connection = nil
        status = .disconnected
    }

    private func startConnection() {
        status = .connecting

        let params = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        guard let url = URL(string: "ws://\(host):\(port)/") else {
            status = .failed("Adresse invalide")
            return
        }

        let conn = NWConnection(to: .url(url), using: params)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                switch state {
                case .ready:
                    self.status = .connected
                case .failed(let error):
                    self.status = .failed(error.localizedDescription)
                    self.scheduleReconnectIfNeeded()
                case .cancelled:
                    if self.status != .disconnected {
                        self.status = .disconnected
                    }
                default:
                    break
                }
            }
        }

        conn.start(queue: queue)
        receiveLoop(on: conn)
    }

    private func scheduleReconnectIfNeeded() {
        guard shouldStayConnected else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled, self.shouldStayConnected else { return }
            self.startConnection()
        }
    }

    private func receiveLoop(on conn: NWConnection) {
        conn.receiveMessage { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in
                    self.status = .failed(error.localizedDescription)
                    self.scheduleReconnectIfNeeded()
                }
                return
            }
            if !isComplete {
                // Message partiel, on ignore côté client : on n'attend aucune réponse du serveur pour l'instant.
            }
            self.receiveLoop(on: conn)
        }
    }

    // MARK: - Envoi des inputs

    func sendButton(name: String, pressed: Bool) {
        send(json: ["type": "button", "name": name, "pressed": pressed])
    }

    func sendStick(name: String, x: Double, y: Double) {
        send(json: ["type": "stick", "name": name, "x": x, "y": y])
    }

    func sendTrigger(name: String, value: Double) {
        send(json: ["type": "trigger", "name": name, "value": value])
    }

    private func send(json: [String: Any]) {
        guard let conn = connection, status == .connected else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "gamepadMessage", metadata: [metadata])

        conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}
