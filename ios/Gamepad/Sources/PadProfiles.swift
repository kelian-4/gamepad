import Foundation

struct PadProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var layout: PadLayout
}

enum PadProfileStore {
    static let storageKey = "gamepad.profiles.v1"
    static let maxNameLength = 40

    static func load() -> [PadProfile] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([PadProfile].self, from: data) else {
            return []
        }
        return saved.filter { $0.layout.isPlausible }
    }

    static func save(_ profiles: [PadProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func normalized(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
    }

    static func upserting(name: String, layout: PadLayout, into profiles: [PadProfile]) -> [PadProfile] {
        var result = profiles
        let clean = normalized(name)
        if let idx = result.firstIndex(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) {
            result[idx].layout = layout
        } else {
            result.append(PadProfile(id: UUID(), name: clean, layout: layout))
        }
        return result
    }
}

struct PadElementEdit {
    var cx: Double?
    var cy: Double?
    var scale: Double?
    var visible: Bool?
}

extension PadLayout {
    func applying(_ edits: [String: PadElementEdit]) -> PadLayout {
        var result = self
        for idx in result.elements.indices {
            guard let edit = edits[result.elements[idx].id] else { continue }
            if let cx = edit.cx { result.elements[idx].cx = cx }
            if let cy = edit.cy { result.elements[idx].cy = cy }
            if let scale = edit.scale { result.elements[idx].scale = scale }
            if let visible = edit.visible { result.elements[idx].visible = visible }
        }
        return result
    }
}

struct PadTemplate: Identifiable {
    let id: String
    let title: String
    let detail: String
    let layout: PadLayout

    static var all: [PadTemplate] {
        let base = PadLayout.layout(for: .xbox)
        let hidden = PadElementEdit(visible: false)
        return [
            PadTemplate(
                id: "course",
                title: "Course",
                detail: "Grandes gâchettes pour accélérer et freiner, stick gauche pour diriger. Croix et stick droit masqués.",
                layout: base.applying([
                    "left": PadElementEdit(cx: 0.22, cy: 0.55, scale: 1.2),
                    "l2": PadElementEdit(cx: 0.06, cy: 0.55, scale: 1.4),
                    "r2": PadElementEdit(cx: 0.94, cy: 0.55, scale: 1.4),
                    "dpad": hidden,
                    "right": hidden
                ])
            ),
            PadTemplate(
                id: "plateforme",
                title: "Plateforme",
                detail: "Grande croix à gauche, gros boutons A/B/X/Y. Sticks masqués.",
                layout: base.applying([
                    "dpad": PadElementEdit(cx: 0.22, cy: 0.62, scale: 1.4),
                    "a": PadElementEdit(scale: 1.15),
                    "b": PadElementEdit(scale: 1.15),
                    "x": PadElementEdit(scale: 1.15),
                    "y": PadElementEdit(scale: 1.15),
                    "left": hidden,
                    "right": hidden
                ])
            ),
            PadTemplate(
                id: "combat",
                title: "Combat",
                detail: "Croix directionnelle large pour les déplacements, boutons d'action agrandis. Sticks masqués.",
                layout: base.applying([
                    "dpad": PadElementEdit(cx: 0.22, cy: 0.62, scale: 1.3),
                    "a": PadElementEdit(scale: 1.15),
                    "b": PadElementEdit(scale: 1.15),
                    "x": PadElementEdit(scale: 1.15),
                    "y": PadElementEdit(scale: 1.15),
                    "left": hidden,
                    "right": hidden
                ])
            ),
            PadTemplate(
                id: "action",
                title: "Action / FPS",
                detail: "Deux sticks et gâchettes agrandis pour viser et se déplacer, croix réduite.",
                layout: base.applying([
                    "left": PadElementEdit(scale: 1.15),
                    "right": PadElementEdit(scale: 1.15),
                    "dpad": PadElementEdit(scale: 0.9),
                    "l2": PadElementEdit(scale: 1.2),
                    "r2": PadElementEdit(scale: 1.2)
                ])
            )
        ]
    }
}
