import SwiftUI

struct PadView: View {
    @EnvironmentObject var state: GamepadState
    @State private var bridge: PadBridge?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()

                if let bridge {
                    PadSurface(controls: layout(in: geo.size), delegate: bridge)
                        .ignoresSafeArea()
                }

                statusBar
                    .padding(.top, geo.safeAreaInsets.top + 6)
                    .padding(.leading, max(geo.safeAreaInsets.leading, 16) + 8)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            if bridge == nil { bridge = PadBridge(connection: state.connection) }
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
            if let ms = state.connection.latencyMs {
                Text("\(ms) ms")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(latencyColor(ms))
            }
        }
    }

    private func layout(in size: CGSize) -> [PadControl] {
        let w = size.width
        let h = size.height
        let midX = w / 2

        let stickSize: CGFloat = min(150, h * 0.36)
        let dpadSize: CGFloat = min(132, h * 0.32)
        let btn: CGFloat = min(58, h * 0.14)
        let gap: CGFloat = btn * 0.12
        let shoulderW: CGFloat = 92
        let shoulderH: CGFloat = 42

        let leftStick = CGRect(x: midX - w * 0.30 - stickSize / 2, y: h * 0.20, width: stickSize, height: stickSize)
        let dpad = CGRect(x: midX - w * 0.20 - dpadSize / 2, y: h * 0.58, width: dpadSize, height: dpadSize)

        let abxyCenter = CGPoint(x: midX + w * 0.30, y: h * 0.36)
        let step = btn + gap
        let rightStick = CGRect(x: midX + w * 0.20 - stickSize / 2, y: h * 0.58, width: stickSize, height: stickSize)

        func circle(_ c: CGPoint) -> CGRect {
            CGRect(x: c.x - btn / 2, y: c.y - btn / 2, width: btn, height: btn)
        }

        return [
            PadControl(kind: .stick("left"), frame: leftStick, label: ""),
            PadControl(kind: .dpad, frame: dpad, label: ""),
            PadControl(kind: .stick("right"), frame: rightStick, label: ""),
            PadControl(kind: .button("y"), frame: circle(CGPoint(x: abxyCenter.x, y: abxyCenter.y - step)), label: "Y"),
            PadControl(kind: .button("a"), frame: circle(CGPoint(x: abxyCenter.x, y: abxyCenter.y + step)), label: "A"),
            PadControl(kind: .button("x"), frame: circle(CGPoint(x: abxyCenter.x - step, y: abxyCenter.y)), label: "X"),
            PadControl(kind: .button("b"), frame: circle(CGPoint(x: abxyCenter.x + step, y: abxyCenter.y)), label: "B"),
            PadControl(kind: .button("l1"), frame: CGRect(x: midX - w * 0.40, y: 14, width: shoulderW, height: shoulderH), label: "LB"),
            PadControl(kind: .button("r1"), frame: CGRect(x: midX + w * 0.40 - shoulderW, y: 14, width: shoulderW, height: shoulderH), label: "RB"),
            PadControl(kind: .button("mode"), frame: CGRect(x: midX - 22, y: h * 0.34, width: 44, height: 44), label: "◉"),
            PadControl(kind: .button("select"), frame: CGRect(x: midX - 78, y: h * 0.52, width: 70, height: 32), label: "VIEW"),
            PadControl(kind: .button("start"), frame: CGRect(x: midX + 8, y: h * 0.52, width: 70, height: 32), label: "MENU")
        ]
    }

    private func latencyColor(_ ms: Int) -> Color {
        if ms < 20 { return .green }
        if ms < 50 { return .orange }
        return .red
    }

    private var statusColor: Color {
        switch state.connection.status {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    private var statusText: String {
        switch state.connection.status {
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

    init(connection: GamepadConnection) {
        self.connection = connection
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
}

#Preview {
    PadView().environmentObject(GamepadState())
}
