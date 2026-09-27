import SwiftUI
import UIKit

struct GamepadButtonView: View {
    let label: String
    let buttonName: String
    let onPress: (Bool) -> Void

    @State private var isPressed = false
    private let diameter: CGFloat = 58
    private let feedback = UIImpactFeedbackGenerator(style: .rigid)

    var body: some View {
        Text(label)
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .foregroundColor(isPressed ? .black : .white.opacity(0.85))
            .frame(width: diameter, height: diameter)
            .background(
                Circle()
                    .fill(isPressed ? Color.accentColor : Color.white.opacity(0.08))
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1.5))
            )
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

struct ShoulderButtonView: View {
    let label: String
    let buttonName: String
    let onPress: (Bool) -> Void

    @State private var isPressed = false
    private let feedback = UIImpactFeedbackGenerator(style: .rigid)

    var body: some View {
        Text(label)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundColor(isPressed ? .black : .white.opacity(0.85))
            .frame(width: 84, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isPressed ? Color.accentColor : Color.white.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.18), lineWidth: 1.5))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
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

struct SmallButtonView: View {
    let label: String
    let buttonName: String
    let onPress: (Bool) -> Void

    @State private var isPressed = false
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(isPressed ? .black : .white.opacity(0.6))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(isPressed ? Color.accentColor : Color.white.opacity(0.08))
                    .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
            )
            .contentShape(Capsule())
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
