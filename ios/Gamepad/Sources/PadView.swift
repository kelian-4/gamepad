import SwiftUI

struct PadView: View {
    @ObservedObject var connection: GamepadConnection
    @State private var layout = PadLayout.load()
    @State private var settings = PadSettings.load()
    @State private var editing = false
    @State private var showSettings = false
    @State private var bridge: PadBridge?
    @State private var surface: PadSurfaceView?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()

                if let bridge {
                    PadSurface(layout: layout, settings: settings, editing: editing, delegate: bridge) { view in
                        surface = view
                    }
                    .ignoresSafeArea()
                }

                statusBar
                    .padding(.top, geo.safeAreaInsets.top + 6)
                    .padding(.leading, max(geo.safeAreaInsets.leading, 16) + 8)

                if editing {
                    editBar
                        .padding(.top, geo.safeAreaInsets.top + 6)
                        .padding(.trailing, max(geo.safeAreaInsets.trailing, 16) + 8)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            if bridge == nil {
                bridge = PadBridge(
                    connection: connection,
                    onLayout: { updated in
                        layout = updated
                        updated.save()
                    },
                    onOpenSettings: { showSettings = true }
                )
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                settings: $settings,
                onResetLayout: {
                    PadLayout.resetSaved()
                    layout = .standard
                    surface?.layout = .standard
                },
                onEditLayout: {
                    showSettings = false
                    editing = true
                },
                onClose: { showSettings = false }
            )
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            Text(statusText)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.55))
            if let ms = connection.latencyMs {
                Text("\(ms) ms")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(latencyColor(ms))
            }
        }
    }

    private var editBar: some View {
        HStack(spacing: 14) {
            Button("Masquer / afficher") { surface?.toggleSelectedVisibility() }
                .font(.caption.bold())
            Button("Terminer") { editing = false }
                .font(.caption.bold())
                .foregroundColor(.green)
        }
        .foregroundColor(.white.opacity(0.8))
    }

    private func latencyColor(_ ms: Int) -> Color {
        if ms < 20 { return .green }
        if ms < 50 { return .orange }
        return .red
    }

    private var statusColor: Color {
        switch connection.status {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    private var statusText: String {
        if editing { return "Édition : glisse pour déplacer, pince pour redimensionner" }
        switch connection.status {
        case .connected: return "Connecté"
        case .connecting: return "Connexion…"
        case .failed(let message): return message
        case .disconnected: return "Déconnecté"
        }
    }
}

@MainActor
final class PadBridge: PadSurfaceDelegate {
    private let connection: GamepadConnection
    private let onLayout: (PadLayout) -> Void
    private let onOpenSettings: () -> Void

    init(connection: GamepadConnection, onLayout: @escaping (PadLayout) -> Void, onOpenSettings: @escaping () -> Void) {
        self.connection = connection
        self.onLayout = onLayout
        self.onOpenSettings = onOpenSettings
    }

    func button(_ name: String, pressed: Bool) {
        connection.sendButton(name: name, pressed: pressed)
    }

    func stick(_ name: String, x: Double, y: Double) {
        connection.sendStick(name: name, x: x, y: y)
    }

    func dpad(x: Int, y: Int) {
        connection.sendDpad(x: x, y: y)
    }

    func layoutChanged(_ layout: PadLayout) {
        onLayout(layout)
    }

    func openSettings() {
        onOpenSettings()
    }
}

#Preview {
    PadView(connection: GamepadConnection())
}
