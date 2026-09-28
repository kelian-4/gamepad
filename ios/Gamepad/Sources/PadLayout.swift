import Foundation
import CoreGraphics

enum PadElementKind: String, Codable {
    case round
    case pill
    case stick
    case dpad
}

struct PadElement: Codable, Identifiable, Equatable {
    let id: String
    let kind: PadElementKind
    let label: String
    var cx: Double
    var cy: Double
    var scale: Double
    var visible: Bool
}

struct PadLayout: Codable, Equatable {
    var elements: [PadElement]

    static let storageKey = "gamepad.layout.v1"

    static var standard: PadLayout {
        PadLayout(elements: [
            PadElement(id: "left", kind: .stick, label: "", cx: 0.20, cy: 0.42, scale: 1, visible: true),
            PadElement(id: "dpad", kind: .dpad, label: "", cx: 0.30, cy: 0.80, scale: 1, visible: true),
            PadElement(id: "right", kind: .stick, label: "", cx: 0.70, cy: 0.80, scale: 1, visible: true),
            PadElement(id: "y", kind: .round, label: "Y", cx: 0.80, cy: 0.20, scale: 1, visible: true),
            PadElement(id: "x", kind: .round, label: "X", cx: 0.73, cy: 0.40, scale: 1, visible: true),
            PadElement(id: "b", kind: .round, label: "B", cx: 0.87, cy: 0.40, scale: 1, visible: true),
            PadElement(id: "a", kind: .round, label: "A", cx: 0.80, cy: 0.60, scale: 1, visible: true),
            PadElement(id: "l1", kind: .pill, label: "LB", cx: 0.12, cy: 0.09, scale: 1, visible: true),
            PadElement(id: "r1", kind: .pill, label: "RB", cx: 0.88, cy: 0.09, scale: 1, visible: true),
            PadElement(id: "mode", kind: .round, label: "◉", cx: 0.50, cy: 0.38, scale: 0.75, visible: true),
            PadElement(id: "select", kind: .pill, label: "VIEW", cx: 0.44, cy: 0.56, scale: 0.8, visible: true),
            PadElement(id: "start", kind: .pill, label: "MENU", cx: 0.56, cy: 0.56, scale: 0.8, visible: true)
        ])
    }

    static func load() -> PadLayout {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode(PadLayout.self, from: data) else {
            return .standard
        }
        var merged = saved
        for element in standard.elements where !merged.elements.contains(where: { $0.id == element.id }) {
            merged.elements.append(element)
        }
        return merged
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    static func resetSaved() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

extension PadElement {
    func frame(in size: CGSize) -> CGRect {
        let base = baseSize(in: size)
        let w = base.width * scale
        let h = base.height * scale
        return CGRect(x: cx * size.width - w / 2, y: cy * size.height - h / 2, width: w, height: h)
    }

    func baseSize(in size: CGSize) -> CGSize {
        let h = size.height
        switch kind {
        case .stick:
            let d = min(150, h * 0.36)
            return CGSize(width: d, height: d)
        case .dpad:
            let d = min(132, h * 0.32)
            return CGSize(width: d, height: d)
        case .round:
            let d = min(58, h * 0.14)
            return CGSize(width: d, height: d)
        case .pill:
            return CGSize(width: 92, height: 42)
        }
    }
}
