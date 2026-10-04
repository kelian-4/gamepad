import Foundation
import Network

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(String)
}

@MainActor
final class GamepadConnection: ObservableObject {
    @Published private(set) var status: ConnectionStatus = .disconnected
    @Published private(set) var latencyMs: Int?
    @Published private(set) var events: [String] = []

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.kelian.gamepad.ws")
    private var host: String = ""
    private var port: UInt16 = 8765
    private var reconnectTask: Task<Void, Never>?
    private var shouldStayConnected = false
    private var hasConnectedOnce = false
    private var reconnectAttempt = 0
    private static let maxReconnectDelay: UInt64 = 10_000_000_000
    private static let baseReconnectDelay: UInt64 = 500_000_000
    private static let protocolVersion = 1

    private var pingTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var pendingSticks: [String: (x: Double, y: Double)] = [:]
    private var lastSentSticks: [String: (x: Double, y: Double)] = [:]
    private var stickFlushScheduled = false
    private static let stickFlushInterval: UInt64 = 8_000_000

    private func log(_ text: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        events.append("\(f.string(from: Date())) \(text)")
        if events.count > 12 { events.removeFirst(events.count - 12) }
    }

    func connect(host: String, port: UInt16) {
        events.removeAll()
        log("connexion à \(host):\(port)")
        self.host = host
        self.port = port
        shouldStayConnected = true
        hasConnectedOnce = false
        reconnectAttempt = 0
        startConnection()
    }

    func disconnect() {
        shouldStayConnected = false
        hasConnectedOnce = false
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        teardownCurrentConnection()
        status = .disconnected
    }

    private func teardownCurrentConnection() {
        timeoutTask?.cancel()
        timeoutTask = nil
        pingTask?.cancel()
        pingTask = nil
        latencyMs = nil
        pendingSticks.removeAll()
        lastSentSticks.removeAll()
        stickFlushScheduled = false
        guard let old = connection else { return }
        connection = nil
        old.stateUpdateHandler = nil
        old.cancel()
    }

    private func startConnection() {
        reconnectTask?.cancel()
        reconnectTask = nil
        teardownCurrentConnection()

        if hasConnectedOnce {
            status = .reconnecting(attempt: reconnectAttempt)
        } else {
            status = .connecting
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        guard let url = URL(string: "ws://\(host):\(port)/") else {
            status = .failed("Adresse invalide")
            return
        }

        let conn = NWConnection(to: .url(url), using: params)
        connection = conn

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            Task { @MainActor in
                guard let self, let conn, self.connection === conn else { return }
                switch state {
                case .ready:
                    self.log("prêt, handshake…")
                    self.timeoutTask?.cancel()
                    self.timeoutTask = nil
                    self.sendHello()
                    self.armTimeout(for: conn)
                case .failed(let error):
                    self.log("échec: \(error.localizedDescription)")
                    self.handleConnectionLoss(error.localizedDescription)
                case .waiting(let error):
                    self.log("attente: \(error.localizedDescription)")
                    self.status = self.hasConnectedOnce ? .reconnecting(attempt: self.reconnectAttempt) : .connecting
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }

        conn.start(queue: queue)
        receiveLoop(on: conn)
        armTimeout(for: conn)
    }

    private func armTimeout(for conn: NWConnection) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self, weak conn] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, let self, let conn, self.connection === conn else { return }
            if self.status != .connected {
                self.log("délai dépassé")
                self.handleConnectionLoss("Délai dépassé. Vérifie que le serveur est bien lancé sur la machine, et Réglages > Confidentialité > Réseau local")
            }
        }
    }

    private func handleConnectionLoss(_ message: String) {
        teardownCurrentConnection()
        if shouldStayConnected && hasConnectedOnce {
            reconnectAttempt += 1
            status = .reconnecting(attempt: reconnectAttempt)
            log("perte de connexion: \(message)")
        } else {
            status = .failed(message)
        }
        scheduleReconnectIfNeeded()
    }

    private func scheduleReconnectIfNeeded() {
        guard shouldStayConnected, hasConnectedOnce else { return }
        reconnectTask?.cancel()
        let exponent = min(reconnectAttempt, 5)
        let scaled = Self.baseReconnectDelay * UInt64(1 << exponent)
        let delay = min(scaled, Self.maxReconnectDelay)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled, self.shouldStayConnected else { return }
            self.startConnection()
        }
    }

    private func receiveLoop(on conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, _, _, error in
            Task { @MainActor in
                guard let self, let conn, self.connection === conn else { return }
                if let error {
                    self.log("réception: \(error.localizedDescription)")
                    self.handleConnectionLoss(error.localizedDescription)
                    return
                }
                if let data { self.handleIncoming(data) }
                self.receiveLoop(on: conn)
            }
        }
    }

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let t = DispatchTime.now().uptimeNanoseconds
                self.sendRaw("{\"type\":\"ping\",\"t\":\(t)}")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func sendHello() {
        sendRawUnconditionally("{\"type\":\"hello\",\"protocolVersion\":\(Self.protocolVersion),\"platform\":\"ios\"}")
    }

    private func handleIncoming(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "ping":
            guard let sent = (obj["t"] as? NSNumber)?.uint64Value else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now >= sent else { return }
            latencyMs = Int((now - sent) / 1_000_000)

        case "hello_ack":
            let ok = (obj["ok"] as? Bool) ?? false
            if ok {
                log("appairage réussi")
                timeoutTask?.cancel()
                timeoutTask = nil
                reconnectAttempt = 0
                hasConnectedOnce = true
                status = .connected
                startPing()
            } else {
                let reason = (obj["reason"] as? String) ?? "appairage refusé"
                log("appairage refusé: \(reason)")
                handleConnectionLoss(reason)
            }

        default:
            break
        }
    }

    func sendButton(name: String, pressed: Bool) {
        sendRaw("{\"type\":\"button\",\"name\":\"\(name)\",\"pressed\":\(pressed)}")
    }

    func sendDpad(x: Int, y: Int) {
        sendRaw("{\"type\":\"dpad\",\"x\":\(x),\"y\":\(y)}")
    }

    func sendTrigger(name: String, value: Double) {
        sendRaw("{\"type\":\"trigger\",\"name\":\"\(name)\",\"value\":\(String(format: "%.3f", value))}")
    }

    func sendStick(name: String, x: Double, y: Double) {
        pendingSticks[name] = (x, y)
        let isRelease = x == 0 && y == 0
        if isRelease {
            flushSticks()
            return
        }
        guard !stickFlushScheduled else { return }
        stickFlushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.stickFlushInterval)
            self?.flushSticks()
        }
    }

    private func flushSticks() {
        stickFlushScheduled = false
        let toSend = pendingSticks
        pendingSticks.removeAll()
        for (name, value) in toSend {
            if let last = lastSentSticks[name], last.x == value.x, last.y == value.y { continue }
            lastSentSticks[name] = value
            sendRaw("{\"type\":\"stick\",\"name\":\"\(name)\",\"x\":\(String(format: "%.3f", value.x)),\"y\":\(String(format: "%.3f", value.y))}")
        }
    }

    private func sendRaw(_ json: String) {
        guard status == .connected else { return }
        sendRawUnconditionally(json)
    }

    private func sendRawUnconditionally(_ json: String) {
        guard let conn = connection else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "gamepadMessage", metadata: [metadata])
        conn.send(content: Data(json.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }
}
