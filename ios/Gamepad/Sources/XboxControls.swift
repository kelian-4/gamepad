import SwiftUI
import UIKit

struct DPadView: View {
    let onChange: (Int, Int) -> Void

    private let size: CGFloat = 132
    private let deadZone: CGFloat = 14

    @State private var current: (x: Int, y: Int) = (0, 0)
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.06))
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1.5))

            arrow("chevron.up", active: current.y == -1, offset: CGSize(width: 0, height: -44))
            arrow("chevron.down", active: current.y == 1, offset: CGSize(width: 0, height: 44))
            arrow("chevron.left", active: current.x == -1, offset: CGSize(width: -44, height: 0))
            arrow("chevron.right", active: current.x == 1, offset: CGSize(width: 44, height: 0))
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    let dx = value.location.x - size / 2
                    let dy = value.location.y - size / 2
                    var x = 0
                    var y = 0
                    if abs(dx) > deadZone || abs(dy) > deadZone {
                        if abs(dx) > abs(dy) * 0.6 { x = dx > 0 ? 1 : -1 }
                        if abs(dy) > abs(dx) * 0.6 { y = dy > 0 ? 1 : -1 }
                    }
                    update(x, y)
                }
                .onEnded { _ in update(0, 0) }
        )
    }

    private func arrow(_ symbol: String, active: Bool, offset: CGSize) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .bold))
            .foregroundColor(active ? .accentColor : .white.opacity(0.55))
            .offset(offset)
    }

    private func update(_ x: Int, _ y: Int) {
        guard x != current.x || y != current.y else { return }
        current = (x, y)
        if x != 0 || y != 0 { feedback.impactOccurred() }
        onChange(x, y)
    }
}

struct StickClickButton: View {
    let onPress: (Bool) -> Void
    @State private var isPressed = false
    private let feedback = UIImpactFeedbackGenerator(style: .medium)

    var body: some View {
        Text("●")
            .font(.system(size: 9))
            .foregroundColor(isPressed ? .black : .white.opacity(0.5))
            .frame(width: 30, height: 30)
            .background(Circle().fill(isPressed ? Color.accentColor : Color.white.opacity(0.08)))
            .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed {
                            isPressed = true
                            feedback.impactOccurred()
                            onPress(true)
                        }
                    }
                    .onEnded { _ in
                        isPressed = false
                        onPress(false)
                    }
            )
    }
}

struct XboxCenterButton: View {
    let onPress: (Bool) -> Void
    @State private var isPressed = false
    private let feedback = UIImpactFeedbackGenerator(style: .medium)

    var body: some View {
        Image(systemName: "circle.hexagongrid.fill")
            .font(.system(size: 20))
            .foregroundColor(isPressed ? .black : .white.opacity(0.75))
            .frame(width: 44, height: 44)
            .background(Circle().fill(isPressed ? Color.accentColor : Color.white.opacity(0.1)))
            .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1.5))
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed {
                            isPressed = true
                            feedback.impactOccurred()
                            onPress(true)
                        }
                    }
                    .onEnded { _ in
                        isPressed = false
                        onPress(false)
                    }
            )
    }
}
