import SwiftUI
import UIKit

enum ControlKind {
    case button(String)
    case stick(String)
    case dpad
}

struct PadControl {
    let kind: ControlKind
    let frame: CGRect
    let label: String
}

@MainActor
protocol PadSurfaceDelegate: AnyObject {
    func button(_ name: String, pressed: Bool)
    func stick(_ name: String, x: Double, y: Double)
    func dpad(x: Int, y: Int)
}

final class PadSurfaceView: UIView {
    weak var delegate: PadSurfaceDelegate?

    var controls: [PadControl] = [] {
        didSet { setNeedsDisplay() }
    }

    private struct Tracked {
        let index: Int
        var lastDpad: (Int, Int) = (0, 0)
    }

    private var tracked: [ObjectIdentifier: Tracked] = [:]
    private var pressedButtons: Set<String> = []
    private var stickOffsets: [String: CGPoint] = [:]
    private var dpadState: (Int, Int) = (0, 0)
    private let impact = UIImpactFeedbackGenerator(style: .rigid)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = .clear
        impact.prepare()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            guard let index = controls.lastIndex(where: { hit($0, point) }) else { continue }
            tracked[ObjectIdentifier(touch)] = Tracked(index: index)
            apply(index: index, point: point, began: true)
        }
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let entry = tracked[ObjectIdentifier(touch)] else { continue }
            apply(index: entry.index, point: touch.location(in: self), began: false)
        }
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        release(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        release(touches)
    }

    private func release(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let entry = tracked.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            let control = controls[entry.index]
            switch control.kind {
            case .button(let name):
                if pressedButtons.remove(name) != nil {
                    delegate?.button(name, pressed: false)
                }
            case .stick(let name):
                stickOffsets[name] = .zero
                delegate?.stick(name, x: 0, y: 0)
            case .dpad:
                dpadState = (0, 0)
                delegate?.dpad(x: 0, y: 0)
            }
        }
        setNeedsDisplay()
    }

    private func hit(_ control: PadControl, _ point: CGPoint) -> Bool {
        switch control.kind {
        case .button(let name) where control.label.count == 1 && name != "l1" && name != "r1":
            return distance(point, center(of: control.frame)) <= control.frame.width / 2 + 6
        case .stick, .dpad:
            return distance(point, center(of: control.frame)) <= control.frame.width / 2 + 10
        default:
            return control.frame.insetBy(dx: -6, dy: -6).contains(point)
        }
    }

    private func apply(index: Int, point: CGPoint, began: Bool) {
        let control = controls[index]
        switch control.kind {
        case .button(let name):
            if !pressedButtons.contains(name) {
                pressedButtons.insert(name)
                impact.impactOccurred()
                delegate?.button(name, pressed: true)
            }
        case .stick(let name):
            let c = center(of: control.frame)
            let radius = (control.frame.width - 64) / 2
            var dx = point.x - c.x
            var dy = point.y - c.y
            let d = hypot(dx, dy)
            if d > radius {
                dx = dx / d * radius
                dy = dy / d * radius
            }
            stickOffsets[name] = CGPoint(x: dx, y: dy)
            delegate?.stick(name, x: Double(dx / radius), y: Double(dy / radius))
        case .dpad:
            let c = center(of: control.frame)
            let dx = point.x - c.x
            let dy = point.y - c.y
            var x = 0
            var y = 0
            if abs(dx) > 10 || abs(dy) > 10 {
                if abs(dx) > abs(dy) * 0.6 { x = dx > 0 ? 1 : -1 }
                if abs(dy) > abs(dx) * 0.6 { y = dy > 0 ? 1 : -1 }
            }
            if (x, y) != dpadState {
                if x != 0 || y != 0 { impact.impactOccurred() }
                dpadState = (x, y)
                delegate?.dpad(x: x, y: y)
            }
        }
    }

    private func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    override func draw(_ rect: CGRect) {
        let accent = UIColor.tintColor
        let base = UIColor.white.withAlphaComponent(0.08)
        let stroke = UIColor.white.withAlphaComponent(0.18)

        for control in controls {
            switch control.kind {
            case .button(let name):
                let pressed = pressedButtons.contains(name)
                let isRound = control.label.count == 1 && name != "l1" && name != "r1"
                let path = isRound
                    ? UIBezierPath(ovalIn: control.frame)
                    : UIBezierPath(roundedRect: control.frame, cornerRadius: control.frame.height / 2.4)
                (pressed ? accent : base).setFill()
                path.fill()
                stroke.setStroke()
                path.lineWidth = 1.5
                path.stroke()
                drawLabel(control.label, in: control.frame, color: pressed ? .black : UIColor.white.withAlphaComponent(0.85), size: isRound ? 20 : 14)

            case .stick(let name):
                let ring = UIBezierPath(ovalIn: control.frame)
                base.setFill()
                ring.fill()
                stroke.setStroke()
                ring.lineWidth = 1.5
                ring.stroke()
                let offset = stickOffsets[name] ?? .zero
                let c = center(of: control.frame)
                let nub = CGRect(x: c.x + offset.x - 32, y: c.y + offset.y - 32, width: 64, height: 64)
                let active = offset != .zero
                (active ? accent : accent.withAlphaComponent(0.75)).setFill()
                UIBezierPath(ovalIn: nub).fill()

            case .dpad:
                let ring = UIBezierPath(ovalIn: control.frame)
                base.setFill()
                ring.fill()
                stroke.setStroke()
                ring.lineWidth = 1.5
                ring.stroke()
                let c = center(of: control.frame)
                let arrows: [(String, CGPoint, Bool)] = [
                    ("▲", CGPoint(x: c.x, y: c.y - 44), dpadState.1 == -1),
                    ("▼", CGPoint(x: c.x, y: c.y + 44), dpadState.1 == 1),
                    ("◀", CGPoint(x: c.x - 44, y: c.y), dpadState.0 == -1),
                    ("▶", CGPoint(x: c.x + 44, y: c.y), dpadState.0 == 1)
                ]
                for (glyph, p, active) in arrows {
                    let r = CGRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32)
                    drawLabel(glyph, in: r, color: active ? accent : UIColor.white.withAlphaComponent(0.55), size: 18)
                }
            }
        }
    }

    private func drawLabel(_ text: String, in rect: CGRect, color: UIColor, size: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: color
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let sz = s.size()
        s.draw(at: CGPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
    }
}

struct PadSurface: UIViewRepresentable {
    let controls: [PadControl]
    let delegate: PadSurfaceDelegate

    func makeUIView(context: Context) -> PadSurfaceView {
        let v = PadSurfaceView()
        v.delegate = delegate
        v.controls = controls
        return v
    }

    func updateUIView(_ uiView: PadSurfaceView, context: Context) {
        uiView.delegate = delegate
        if uiView.controls.count != controls.count || zip(uiView.controls, controls).contains(where: { $0.frame != $1.frame }) {
            uiView.controls = controls
        }
    }
}
