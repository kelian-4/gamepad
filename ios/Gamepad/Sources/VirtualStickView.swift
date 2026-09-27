import SwiftUI

struct VirtualStickView: View {
    let stickName: String
    let onChange: (Double, Double) -> Void

    private let baseDiameter: CGFloat = 140
    private let nubDiameter: CGFloat = 60

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false

    private var radius: CGFloat { (baseDiameter - nubDiameter) / 2 }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.06))
                .overlay(
                    Circle().stroke(Color.white.opacity(0.18), lineWidth: 1.5)
                )
                .frame(width: baseDiameter, height: baseDiameter)

            Circle()
                .fill(Color.accentColor.opacity(isDragging ? 0.95 : 0.75))
                .frame(width: nubDiameter, height: nubDiameter)
                .offset(dragOffset)
                .shadow(color: Color.accentColor.opacity(0.4), radius: isDragging ? 10 : 4)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    isDragging = true
                    let translation = value.translation
                    let distance = sqrt(translation.width * translation.width + translation.height * translation.height)

                    if distance > radius {
                        let angle = atan2(translation.height, translation.width)
                        dragOffset = CGSize(
                            width: cos(angle) * radius,
                            height: sin(angle) * radius
                        )
                    } else {
                        dragOffset = translation
                    }

                    let normX = Double(dragOffset.width / radius)
                    let normY = Double(dragOffset.height / radius)
                    onChange(normX, normY)
                }
                .onEnded { _ in
                    isDragging = false
                    dragOffset = .zero
                    onChange(0, 0)
                }
        )
        .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.7), value: isDragging)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        VirtualStickView(stickName: "left") { _, _ in }
    }
}
