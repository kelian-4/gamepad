import Foundation
import CoreGraphics

enum PadElementKind: String, Codable {
    case round
    case pill
    case stick
    case dpad
    case trigger
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

    static let storageKey = "gamepad.layout.v2"

    static var standard: PadLayout { layout(for: .xbox) }

    static func layout(for preset: PadPreset) -> PadLayout {
        let xbox = PadLayout(elements: [
            PadElement(id: "left", kind: .stick, label: "", cx: 0.20, cy: 0.42, scale: 1, visible: true),
            PadElement(id: "dpad", kind: .dpad, label: "", cx: 0.30, cy: 0.80, scale: 1, visible: true),
            PadElement(id: "right", kind: .stick, label: "", cx: 0.70, cy: 0.80, scale: 1, visible: true),
            PadElement(id: "y", kind: .round, label: "Y", cx: 0.80, cy: 0.28, scale: 1, visible: true),
            PadElement(id: "x", kind: .round, label: "X", cx: 0.745, cy: 0.42, scale: 1, visible: true),
            PadElement(id: "b", kind: .round, label: "B", cx: 0.855, cy: 0.42, scale: 1, visible: true),
            PadElement(id: "a", kind: .round, label: "A", cx: 0.80, cy: 0.56, scale: 1, visible: true),
            PadElement(id: "l1", kind: .pill, label: "LB", cx: 0.14, cy: 0.16, scale: 1, visible: true),
            PadElement(id: "r1", kind: .pill, label: "RB", cx: 0.86, cy: 0.26, scale: 1, visible: true),
            PadElement(id: "l2", kind: .trigger, label: "LT", cx: 0.06, cy: 0.42, scale: 1, visible: true),
            PadElement(id: "r2", kind: .trigger, label: "RT", cx: 0.94, cy: 0.42, scale: 1, visible: true),
            PadElement(id: "mode", kind: .round, label: "◉", cx: 0.50, cy: 0.38, scale: 0.75, visible: true),
            PadElement(id: "select", kind: .pill, label: "VIEW", cx: 0.44, cy: 0.56, scale: 0.8, visible: true),
            PadElement(id: "start", kind: .pill, label: "MENU", cx: 0.56, cy: 0.56, scale: 0.8, visible: true)
        ])

        switch preset {
        case .xbox, .custom:
            return xbox
        case .playstation:
            var ps = xbox
            guard let leftIdx = ps.elements.firstIndex(where: { $0.id == "left" }),
                  let dpadIdx = ps.elements.firstIndex(where: { $0.id == "dpad" }) else {
                return ps
            }
            let leftPos = (ps.elements[leftIdx].cx, ps.elements[leftIdx].cy)
            let dpadPos = (ps.elements[dpadIdx].cx, ps.elements[dpadIdx].cy)
            ps.elements[leftIdx].cx = dpadPos.0
            ps.elements[leftIdx].cy = dpadPos.1
            ps.elements[dpadIdx].cx = leftPos.0
            ps.elements[dpadIdx].cy = leftPos.1
            return ps
        }
    }

    static func load() -> PadLayout {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode(PadLayout.self, from: data),
              saved.isPlausible else {
            return .standard
        }
        var merged = saved
        for element in standard.elements where !merged.elements.contains(where: { $0.id == element.id }) {
            merged.elements.append(element)
        }
        let legacyShoulderPositions: [(String, Double, Double)] = [
            ("l1", 0.12, 0.09), ("r1", 0.88, 0.09),
            ("r1", 0.86, 0.16)
        ]
        for (id, oldCx, oldCy) in legacyShoulderPositions {
            if let idx = merged.elements.firstIndex(where: { $0.id == id }),
               abs(merged.elements[idx].cx - oldCx) < 0.001,
               abs(merged.elements[idx].cy - oldCy) < 0.001,
               let fresh = standard.elements.first(where: { $0.id == id }) {
                merged.elements[idx].cx = fresh.cx
                merged.elements[idx].cy = fresh.cy
            }
        }
        return merged
    }

    var isPlausible: Bool {
        let ids = Set(elements.map(\.id))
        let knownIDs = Set(PadLayout.standard.elements.map(\.id))
        guard !ids.isEmpty, ids.isSubset(of: knownIDs) else { return false }
        return elements.allSatisfy { el in
            el.cx >= 0 && el.cx <= 1 && el.cy >= 0 && el.cy <= 1 && el.scale >= 0.4 && el.scale <= 2.5
        }
    }

    func matchesPositions(of other: PadLayout) -> Bool {
        let tolerance = 0.005
        for element in elements {
            guard let match = other.elements.first(where: { $0.id == element.id }) else { return false }
            if abs(element.cx - match.cx) > tolerance || abs(element.cy - match.cy) > tolerance {
                return false
            }
        }
        return true
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
        case .trigger:
            return CGSize(width: 56, height: 120)
        }
    }
}
