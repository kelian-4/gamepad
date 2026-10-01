import SwiftUI

enum PadPreset: String, Codable, CaseIterable, Identifiable {
    case xbox
    case playstation
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xbox: return "Xbox"
        case .playstation: return "PlayStation"
        case .custom: return "Custom"
        }
    }

    var accent: Color {
        switch self {
        case .xbox: return Color(red: 0.09, green: 0.64, blue: 0.29)
        case .playstation: return Color(red: 0.0, green: 0.42, blue: 0.87)
        case .custom: return .accentColor
        }
    }

    var centerGlyph: String {
        switch self {
        case .xbox: return "circle.hexagongrid.fill"
        case .playstation: return "capsule.portrait.fill"
        case .custom: return "gearshape.fill"
        }
    }

    func label(for buttonID: String) -> String {
        switch (self, buttonID) {
        case (.playstation, "a"): return "✕"
        case (.playstation, "b"): return "○"
        case (.playstation, "x"): return "□"
        case (.playstation, "y"): return "△"
        case (.playstation, "l1"): return "L1"
        case (.playstation, "r1"): return "R1"
        case (.playstation, "select"): return "SHARE"
        case (.playstation, "start"): return "OPTIONS"
        case (_, "a"): return "A"
        case (_, "b"): return "B"
        case (_, "x"): return "X"
        case (_, "y"): return "Y"
        case (_, "l1"): return "LB"
        case (_, "r1"): return "RB"
        case (_, "select"): return "VIEW"
        case (_, "start"): return "MENU"
        default: return buttonID.uppercased()
        }
    }

    func buttonColor(for buttonID: String) -> Color? {
        guard self == .playstation else { return nil }
        switch buttonID {
        case "a": return Color(red: 0.35, green: 0.62, blue: 0.93)
        case "b": return Color(red: 0.87, green: 0.32, blue: 0.35)
        case "x": return Color(red: 0.85, green: 0.62, blue: 0.85)
        case "y": return Color(red: 0.33, green: 0.75, blue: 0.63)
        default: return nil
        }
    }
}

enum PadBackground: String, Codable, CaseIterable, Identifiable {
    case black
    case charcoal
    case navy
    case forest
    case plum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .black: return "Noir"
        case .charcoal: return "Anthracite"
        case .navy: return "Marine"
        case .forest: return "Forêt"
        case .plum: return "Prune"
        }
    }

    var color: Color {
        switch self {
        case .black: return .black
        case .charcoal: return Color(red: 0.11, green: 0.11, blue: 0.13)
        case .navy: return Color(red: 0.05, green: 0.08, blue: 0.16)
        case .forest: return Color(red: 0.05, green: 0.12, blue: 0.09)
        case .plum: return Color(red: 0.14, green: 0.06, blue: 0.14)
        }
    }
}

struct PadSettings: Codable, Equatable {
    var preset: PadPreset
    var globalScale: Double
    var hapticsEnabled: Bool
    var background: PadBackground

    static let storageKey = "gamepad.settings.v1"

    static var standard: PadSettings {
        PadSettings(preset: .xbox, globalScale: 1.0, hapticsEnabled: true, background: .black)
    }

    static func load() -> PadSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode(PadSettings.self, from: data) else {
            return .standard
        }
        return saved
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
