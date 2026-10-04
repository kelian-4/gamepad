import Foundation
import Network

@MainActor
final class ServerDiscovery: ObservableObject {
    struct Found: Identifiable, Equatable {
        let id: String
        let name: String
        let host: String
        let port: UInt16
    }

    @Published private(set) var isSearching = false
    @Published private(set) var results: [Found] = []
    @Published private(set) var searchedWithNoResult = false

    private var browser: NWBrowser?

    func start() {
        stop()
        results = []
        searchedWithNoResult = false
        isSearching = true

        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_gamepad._tcp", domain: nil), using: params)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.handle(results: results)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed = state {
                    self?.isSearching = false
                }
            }
        }
        browser.start(queue: .main)

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self else { return }
            self.isSearching = false
            self.searchedWithNoResult = self.results.isEmpty
        }
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    private func handle(results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            resolve(result: result, name: name)
        }
    }

    private func resolve(result: NWBrowser.Result, name: String) {
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            if let path = connection.currentPath,
               let endpoint = path.remoteEndpoint,
               case let .hostPort(host, port) = endpoint {
                let hostString = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
                Task { @MainActor in
                    guard let self else { return }
                    let found = Found(id: name, name: name, host: hostString, port: port.rawValue)
                    if !self.results.contains(found) {
                        self.results.append(found)
                    }
                }
            }
            connection.cancel()
        }
        connection.start(queue: .main)
    }
}
