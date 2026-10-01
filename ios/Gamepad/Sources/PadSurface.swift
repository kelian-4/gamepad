import SwiftUI
import UIKit

@MainActor
protocol PadSurfaceDelegate: AnyObject {
    func button(_ name: String, pressed: Bool)
    func stick(_ name: String, x: Double, y: Double)
    func dpad(x: Int, y: Int)
    func layoutChanged(_ layout: PadLayout)
    func openSettings()
    func selectionChanged(_ id: String?)
}

final class PadSurfaceView: UIView {
    weak var delegate: PadSurfaceDelegate?

    var layout: PadLayout = .standard {
        didSet { setNeedsDisplay() }
    }

    var settings: PadSettings = .standard {
        didSet { setNeedsDisplay() }
    }

    var editing = false {
        didSet {
            if editing { releaseEverything() }
            selectedID = nil
            setNeedsDisplay()
        }
    }

    private static let minimumPress: TimeInterval = 0.07

    private var touchTargets: [ObjectIdentifier: String] = [:]
    private var pressedSince: [String: CFTimeInterval] = [:]
    private var pendingRelease: [String: DispatchWorkItem] = [:]
    private var stickOffsets: [String: CGPoint] = [:]
    private var dpadState: (Int, Int) = (0, 0)
    private var selectedID: String? {
        didSet {
            if oldValue != selectedID { delegate?.selectionChanged(selectedID) }
        }
    }
    private var dragOrigin: [ObjectIdentifier: (cx: Double, cy: Double, point: CGPoint)] = [:]
    private var pinch: UIPinchGestureRecognizer?
    private var pinchStartScale = 1.0
    private let impact = UIImpactFeedbackGenerator(style: .rigid)

    private func hapticTap() {
        guard settings.hapticsEnabled else { return }
        impact.impactOccurred()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        impact.prepare()
        let recognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        recognizer.cancelsTouchesInView = false
        addGestureRecognizer(recognizer)
        pinch = recognizer
    }

    required init?(coder: NSCoder) { fatalError() }

    private func element(at point: CGPoint) -> PadElement? {
        layout.elements.reversed().first { el0 in
            guard el0.visible || editing else { return false }
            var el = el0
            el.scale *= settings.globalScale
            let f = el.frame(in: bounds.size)
            switch el.kind {
            case .round, .stick, .dpad:
                let c = CGPoint(x: f.midX, y: f.midY)
                return hypot(point.x - c.x, point.y - c.y) <= f.width / 2 + 8
            case .pill:
                return f.insetBy(dx: -8, dy: -8).contains(point)
            }
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            guard let el = element(at: point) else {
                if editing { selectedID = nil }
                continue
            }
            let key = ObjectIdentifier(touch)
            touchTargets[key] = el.id
            if editing {
                selectedID = el.id
                dragOrigin[key] = (el.cx, el.cy, point)
                pinchStartScale = el.scale
            } else {
                engage(el, at: point)
            }
        }
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let key = ObjectIdentifier(touch)
            guard let id = touchTargets[key],
                  let idx = layout.elements.firstIndex(where: { $0.id == id }) else { continue }
            let point = touch.location(in: self)
            if editing {
                guard let origin = dragOrigin[key], bounds.width > 0, bounds.height > 0 else { continue }
                let nx = origin.cx + Double((point.x - origin.point.x) / bounds.width)
                let ny = origin.cy + Double((point.y - origin.point.y) / bounds.height)
                layout.elements[idx].cx = min(max(nx, 0.03), 0.97)
                layout.elements[idx].cy = min(max(ny, 0.05), 0.95)
            } else {
                let el = layout.elements[idx]
                switch el.kind {
                case .round, .pill:
                    var scaled = el
                    scaled.scale *= settings.globalScale
                    let f = scaled.frame(in: bounds.size)
                    let c = CGPoint(x: f.midX, y: f.midY)
                    let stillInside = el.kind == .round
                        ? hypot(point.x - c.x, point.y - c.y) <= f.width / 2 + 8
                        : f.insetBy(dx: -8, dy: -8).contains(point)
                    if !stillInside {
                        touchTargets.removeValue(forKey: key)
                        release(el.id)
                    }
                case .stick, .dpad:
                    track(el, at: point)
                }
            }
        }
        reconcileStaleButtons()
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    private func finish(_ touches: Set<UITouch>) {
        for touch in touches {
            let key = ObjectIdentifier(touch)
            guard let id = touchTargets.removeValue(forKey: key) else { continue }
            dragOrigin.removeValue(forKey: key)
            if editing {
                delegate?.layoutChanged(layout)
                continue
            }
            guard let el = layout.elements.first(where: { $0.id == id }), el.id != "mode" else { continue }
            disengage(el)
        }
        reconcileStaleButtons()
        setNeedsDisplay()
    }

    private func reconcileStaleButtons() {
        let activeIDs = Set(touchTargets.values)
        for id in Array(pressedSince.keys) where !activeIDs.contains(id) && pendingRelease[id] == nil {
            release(id)
        }
    }

    private func engage(_ el: PadElement, at point: CGPoint) {
        if el.id == "mode" {
            hapticTap()
            delegate?.openSettings()
            return
        }
        switch el.kind {
        case .round, .pill:
            press(el.id)
        case .stick, .dpad:
            track(el, at: point)
        }
    }

    private func track(_ el0: PadElement, at point: CGPoint) {
        var el = el0
        el.scale *= settings.globalScale
        let f = el.frame(in: bounds.size)
        let c = CGPoint(x: f.midX, y: f.midY)
        switch el.kind {
        case .stick:
            let radius = max((f.width - 64 * el.scale) / 2, 1)
            var dx = point.x - c.x
            var dy = point.y - c.y
            let d = hypot(dx, dy)
            if d > radius {
                dx = dx / d * radius
                dy = dy / d * radius
            }
            stickOffsets[el.id] = CGPoint(x: dx, y: dy)
            delegate?.stick(el.id, x: Double(dx / radius), y: Double(dy / radius))
        case .dpad:
            let dx = point.x - c.x
            let dy = point.y - c.y
            var x = 0
            var y = 0
            if abs(dx) > 10 || abs(dy) > 10 {
                if abs(dx) > abs(dy) * 0.6 { x = dx > 0 ? 1 : -1 }
                if abs(dy) > abs(dx) * 0.6 { y = dy > 0 ? 1 : -1 }
            }
            if (x, y) != dpadState {
                if x != 0 || y != 0 { hapticTap() }
                dpadState = (x, y)
                delegate?.dpad(x: x, y: y)
            }
        default:
            break
        }
    }

    private func disengage(_ el: PadElement) {
        switch el.kind {
        case .round, .pill:
            release(el.id)
        case .stick:
            stickOffsets[el.id] = .zero
            delegate?.stick(el.id, x: 0, y: 0)
        case .dpad:
            dpadState = (0, 0)
            delegate?.dpad(x: 0, y: 0)
        }
    }

    private func press(_ id: String) {
        pendingRelease[id]?.cancel()
        pendingRelease[id] = nil
        if pressedSince[id] == nil {
            pressedSince[id] = CACurrentMediaTime()
            hapticTap()
            delegate?.button(id, pressed: true)
        }
    }

    private func release(_ id: String) {
        guard let since = pressedSince[id] else { return }
        let elapsed = CACurrentMediaTime() - since
        let remaining = Self.minimumPress - elapsed
        if remaining <= 0 {
            sendRelease(id)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.sendRelease(id)
        }
        pendingRelease[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    private func sendRelease(_ id: String) {
        pendingRelease[id] = nil
        guard pressedSince[id] != nil else { return }
        pressedSince[id] = nil
        delegate?.button(id, pressed: false)
        setNeedsDisplay()
    }

    private func releaseEverything() {
        for id in Array(pressedSince.keys) {
            pendingRelease[id]?.cancel()
            pendingRelease[id] = nil
            pressedSince[id] = nil
            delegate?.button(id, pressed: false)
        }
        for id in Array(stickOffsets.keys) {
            stickOffsets[id] = .zero
            delegate?.stick(id, x: 0, y: 0)
        }
        if dpadState != (0, 0) {
            dpadState = (0, 0)
            delegate?.dpad(x: 0, y: 0)
        }
        touchTargets.removeAll()
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard editing, let id = selectedID,
              let idx = layout.elements.firstIndex(where: { $0.id == id }) else { return }
        switch recognizer.state {
        case .began:
            pinchStartScale = layout.elements[idx].scale
        case .changed:
            layout.elements[idx].scale = min(max(pinchStartScale * Double(recognizer.scale), 0.5), 2.2)
            setNeedsDisplay()
        case .ended, .cancelled:
            delegate?.layoutChanged(layout)
        default:
            break
        }
    }

    func toggleSelectedVisibility() {
        guard let id = selectedID,
              let idx = layout.elements.firstIndex(where: { $0.id == id }) else { return }
        layout.elements[idx].visible.toggle()
        delegate?.layoutChanged(layout)
        setNeedsDisplay()
    }

    func setSelectedScale(_ scale: Double) {
        guard let id = selectedID,
              let idx = layout.elements.firstIndex(where: { $0.id == id }) else { return }
        layout.elements[idx].scale = min(max(scale, 0.5), 2.2)
        delegate?.layoutChanged(layout)
        setNeedsDisplay()
    }

    var selectedScale: Double? {
        guard let id = selectedID else { return nil }
        return layout.elements.first(where: { $0.id == id })?.scale
    }

    var hasSelection: Bool { selectedID != nil }
    var selectionLabel: String? { selectedID }

    override func draw(_ rect: CGRect) {
        let accent = UIColor(settings.preset.accent)
        let base = UIColor.white.withAlphaComponent(0.08)
        let stroke = UIColor.white.withAlphaComponent(0.18)
        let globalScale = CGFloat(settings.globalScale)

        for el0 in layout.elements {
            var el = el0
            el.scale *= Double(globalScale)
            if !el.visible && !editing { continue }
            let dim: CGFloat = el.visible ? 1 : 0.25
            let f = el.frame(in: bounds.size)
            let selected = editing && el.id == selectedID

            if el.id == "mode" {
                base.withAlphaComponent(0.1 * dim).setFill()
                UIBezierPath(ovalIn: f).fill()
                stroke.withAlphaComponent(0.22 * dim + (selected ? 0.5 : 0)).setStroke()
                let ring = UIBezierPath(ovalIn: f)
                ring.lineWidth = selected ? 2.5 : 1.5
                ring.stroke()
                drawSymbol(editing ? "slider.horizontal.3" : settings.preset.centerGlyph,
                           in: f, color: UIColor.white.withAlphaComponent(0.75 * dim))
                continue
            }

            switch el.kind {
            case .round, .pill:
                let pressed = pressedSince[el.id] != nil
                let path = el.kind == .round
                    ? UIBezierPath(ovalIn: f)
                    : UIBezierPath(roundedRect: f, cornerRadius: f.height / 2.4)
                let themedColor = settings.preset.buttonColor(for: el.id)
                let fillColor: UIColor
                if pressed {
                    fillColor = accent
                } else if let themedColor {
                    fillColor = UIColor(themedColor).withAlphaComponent(0.22 * dim)
                } else {
                    fillColor = base.withAlphaComponent(0.08 * dim)
                }
                fillColor.setFill()
                path.fill()
                stroke.withAlphaComponent(0.18 * dim + (selected ? 0.5 : 0)).setStroke()
                path.lineWidth = selected ? 2.5 : 1.5
                path.stroke()
                drawLabel(settings.preset.label(for: el.id), in: f,
                          color: pressed ? .black : UIColor.white.withAlphaComponent(0.85 * dim),
                          size: (el.kind == .round ? 20 : 14) * CGFloat(el.scale))

            case .stick:
                let ring = UIBezierPath(ovalIn: f)
                base.withAlphaComponent(0.08 * dim).setFill()
                ring.fill()
                stroke.withAlphaComponent(0.18 * dim + (selected ? 0.5 : 0)).setStroke()
                ring.lineWidth = selected ? 2.5 : 1.5
                ring.stroke()
                let offset = stickOffsets[el.id] ?? .zero
                let nubSize = 64 * CGFloat(el.scale)
                let nub = CGRect(x: f.midX + offset.x - nubSize / 2, y: f.midY + offset.y - nubSize / 2,
                                 width: nubSize, height: nubSize)
                accent.withAlphaComponent((offset == .zero ? 0.75 : 1) * dim).setFill()
                UIBezierPath(ovalIn: nub).fill()

            case .dpad:
                let ring = UIBezierPath(ovalIn: f)
                base.withAlphaComponent(0.08 * dim).setFill()
                ring.fill()
                stroke.withAlphaComponent(0.18 * dim + (selected ? 0.5 : 0)).setStroke()
                ring.lineWidth = selected ? 2.5 : 1.5
                ring.stroke()
                let reach = f.width * 0.33
                let arrows: [(String, CGFloat, CGFloat, Bool)] = [
                    ("▲", 0, -reach, dpadState.1 == -1),
                    ("▼", 0, reach, dpadState.1 == 1),
                    ("◀", -reach, 0, dpadState.0 == -1),
                    ("▶", reach, 0, dpadState.0 == 1)
                ]
                for (glyph, ox, oy, active) in arrows {
                    let r = CGRect(x: f.midX + ox - 16, y: f.midY + oy - 16, width: 32, height: 32)
                    drawLabel(glyph, in: r,
                              color: active ? accent : UIColor.white.withAlphaComponent(0.55 * dim),
                              size: 18 * CGFloat(el.scale))
                }
            }
        }
    }

    private func drawSymbol(_ name: String, in rect: CGRect, color: UIColor) {
        let config = UIImage.SymbolConfiguration(pointSize: rect.width * 0.4, weight: .semibold)
        guard let image = UIImage(systemName: name, withConfiguration: config)?
            .withTintColor(color, renderingMode: .alwaysOriginal) else { return }
        let size = image.size
        image.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
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
    let layout: PadLayout
    let settings: PadSettings
    let editing: Bool
    let delegate: PadSurfaceDelegate
    let onReady: (PadSurfaceView) -> Void

    func makeUIView(context: Context) -> PadSurfaceView {
        let v = PadSurfaceView()
        v.delegate = delegate
        v.layout = layout
        v.settings = settings
        v.editing = editing
        DispatchQueue.main.async { onReady(v) }
        return v
    }

    func updateUIView(_ uiView: PadSurfaceView, context: Context) {
        uiView.delegate = delegate
        if uiView.editing != editing { uiView.editing = editing }
        if !editing && uiView.layout != layout { uiView.layout = layout }
        if uiView.settings != settings { uiView.settings = settings }
    }
}
