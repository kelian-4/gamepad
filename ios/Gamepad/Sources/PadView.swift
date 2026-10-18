import SwiftUI
import UIKit

struct PadView: View {
    @ObservedObject var connection: GamepadConnection
    @ObservedObject private var screen: ScreenStreamClient
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("gamepad.stream.quality") private var streamQuality = "auto"
    @AppStorage("gamepad.stream.brightness") private var streamBrightness = 0.8
    @AppStorage("gamepad.buttons.opacity") private var buttonOpacity = 1.0
    @AppStorage("gamepad.background.beforeScreen") private var backgroundBeforeScreen = PadBackground.black.rawValue
    @State private var layout = PadLayout.load()
    @State private var settings = PadSettings.load()
    @State private var editing = false
    @State private var showSettings = false
    @State private var bridge: PadBridge?
    @State private var surface: PadSurfaceView?
    @State private var selectedScale: Double?
    @State private var customBackgroundImage: UIImage? = CustomBackgroundStorage.load()
    @State private var pendingPresetLayoutChange: PadPreset?

    init(connection: GamepadConnection) {
        _connection = ObservedObject(wrappedValue: connection)
        _screen = ObservedObject(wrappedValue: connection.screen)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                backgroundView
                    .ignoresSafeArea()

                if let bridge {
                    PadSurface(layout: layout, settings: settings, editing: editing, delegate: bridge) { view in
                        surface = view
                    }
                    .opacity(editing ? 1 : buttonOpacity)
                    .ignoresSafeArea()
                }

                statusBar
                    .padding(.top, max(geo.safeAreaInsets.top, 8) + 6)
                    .padding(.leading, max(geo.safeAreaInsets.leading, 16) + 8)

                if editing {
                    editBar
                        .padding(.bottom, max(geo.safeAreaInsets.bottom, 8) + 6)
                        .padding(.trailing, max(geo.safeAreaInsets.trailing, 16) + 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            syncStream()
            if bridge == nil {
                bridge = PadBridge(
                    connection: connection,
                    onLayout: { updated in
                        layout = updated
                        updated.save()
                        if let id = surface?.selectionLabel {
                            selectedScale = updated.elements.first(where: { $0.id == id })?.scale
                        }
                    },
                    onOpenSettings: { showSettings = true },
                    onSelectionChanged: { id in
                        selectedScale = id.flatMap { selId in
                            layout.elements.first(where: { $0.id == selId })?.scale
                        }
                    }
                )
            }
        }
        .onDisappear { screen.stop() }
        .onChange(of: settings.background) { _ in syncStream() }
        .onChange(of: connection.status) { _ in syncStream() }
        .onChange(of: connection.streamEndpoint) { _ in syncStream() }
        .onChange(of: streamQuality) { _ in syncStream() }
        .onChange(of: scenePhase) { _ in syncStream() }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                settings: $settings,
                currentLayout: layout,
                onResetLayout: {
                    PadLayout.resetSaved()
                    let resetLayout = PadLayout.layout(for: settings.preset)
                    layout = resetLayout
                    resetLayout.save()
                    surface?.layout = resetLayout
                },
                onEditLayout: {
                    showSettings = false
                    editing = true
                },
                onClose: { showSettings = false },
                onBackgroundImageChanged: {
                    customBackgroundImage = CustomBackgroundStorage.load()
                },
                onImportLayout: { imported in
                    layout = imported
                    imported.save()
                    surface?.layout = imported
                }
            )
        }
        .onChange(of: settings.preset) { newPreset in
            guard newPreset == .xbox || newPreset == .playstation else { return }
            let referenceLayouts: [PadPreset] = [.xbox, .playstation]
            let matchesAnyReference = referenceLayouts.contains { layout.matchesPositions(of: PadLayout.layout(for: $0)) }
            if matchesAnyReference {
                layout = PadLayout.layout(for: newPreset)
                layout.save()
                surface?.layout = layout
            } else {
                pendingPresetLayoutChange = newPreset
            }
        }
        .alert(
            "Appliquer la disposition \(pendingPresetLayoutChange?.title ?? "") ?",
            isPresented: Binding(
                get: { pendingPresetLayoutChange != nil },
                set: { if !$0 { pendingPresetLayoutChange = nil } }
            ),
            presenting: pendingPresetLayoutChange
        ) { preset in
            Button("Remplacer", role: .destructive) {
                layout = PadLayout.layout(for: preset)
                layout.save()
                surface?.layout = layout
                pendingPresetLayoutChange = nil
            }
            Button("Garder ma disposition", role: .cancel) {
                pendingPresetLayoutChange = nil
            }
        } message: { _ in
            Text("Tu as déjà déplacé des éléments. Changer de preset peut aussi repositionner le stick et la croix pour correspondre à la vraie manette. Choisis quoi faire de ta disposition actuelle.")
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        if settings.background == .screen {
            ZStack {
                staticBackground(for: PadBackground(rawValue: backgroundBeforeScreen) ?? .black)
                if screen.state == .active {
                    ScreenStreamView(displayLayer: screen.displayLayer)
                        .allowsHitTesting(false)
                        .overlay(Color.black.opacity(1 - streamBrightness))
                }
            }
            .ignoresSafeArea()
        } else {
            staticBackground(for: settings.background)
        }
    }

    @ViewBuilder
    private func staticBackground(for background: PadBackground) -> some View {
        if background == .custom, let customBackgroundImage {
            GeometryReader { geo in
                Image(uiImage: customBackgroundImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
            .ignoresSafeArea()
            .overlay(Color.black.opacity(0.35))
        } else {
            background.color
        }
    }

    private func syncStream() {
        guard settings.background == .screen,
              scenePhase == .active,
              connection.status == .connected,
              let endpoint = connection.streamEndpoint else {
            screen.stop()
            return
        }
        screen.start(endpoint: endpoint, secret: connection.streamSecret, quality: streamQuality)
    }

    private var streamIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(streamColor)
                .frame(width: 7, height: 7)
            Text(streamText)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
        }
    }

    private var streamColor: Color {
        guard connection.streamEndpoint != nil else { return .red }
        switch screen.state {
        case .active: return .green
        case .waiting: return .orange
        case .unavailable: return .red
        case .off: return .gray
        }
    }

    private var streamText: String {
        guard connection.streamEndpoint != nil else { return "Écran : le serveur ne le propose pas" }
        switch screen.state {
        case .active: return "Écran"
        case .waiting: return "Écran : en attente"
        case .unavailable(let reason): return "Écran : \(reason)"
        case .off: return "Écran : inactif"
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            Text(statusText)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.85))
            if let ms = connection.latencyMs {
                Text("\(ms) ms")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(latencyColor(ms))
            }
            if settings.background == .screen && connection.status == .connected {
                streamIndicator
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var editBar: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 14) {
                Button("Masquer / afficher") { surface?.toggleSelectedVisibility() }
                    .font(.caption.bold())
                Button("Terminer") { editing = false }
                    .font(.caption.bold())
                    .foregroundColor(.green)
            }
            .foregroundColor(.white.opacity(0.9))

            if let scale = selectedScale {
                HStack(spacing: 8) {
                    Image(systemName: "minus.magnifyingglass").font(.caption2)
                    Slider(
                        value: Binding(
                            get: { scale },
                            set: { surface?.setSelectedScale($0) }
                        ),
                        in: 0.5...2.2
                    )
                    .frame(width: 140)
                    Image(systemName: "plus.magnifyingglass").font(.caption2)
                }
                .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.75)))
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
        case .reconnecting: return .orange
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    private var statusText: String {
        if editing { return "Édition : glisse pour déplacer, pince pour redimensionner" }
        switch connection.status {
        case .connected: return "Connecté"
        case .connecting: return "Connexion…"
        case .reconnecting(let attempt): return "Reconnexion… (\(attempt))"
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
    private let onSelectionChanged: (String?) -> Void

    init(connection: GamepadConnection,
         onLayout: @escaping (PadLayout) -> Void,
         onOpenSettings: @escaping () -> Void,
         onSelectionChanged: @escaping (String?) -> Void) {
        self.connection = connection
        self.onLayout = onLayout
        self.onOpenSettings = onOpenSettings
        self.onSelectionChanged = onSelectionChanged
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

    func trigger(_ name: String, value: Double) {
        connection.sendTrigger(name: name, value: value)
    }

    func layoutChanged(_ layout: PadLayout) {
        onLayout(layout)
    }

    func openSettings() {
        onOpenSettings()
    }

    func selectionChanged(_ id: String?) {
        onSelectionChanged(id)
    }
}

#Preview {
    PadView(connection: GamepadConnection())
}
