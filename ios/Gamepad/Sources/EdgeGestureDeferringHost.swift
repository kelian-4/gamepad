import SwiftUI
import UIKit

final class EdgeGestureDeferringViewController: UIViewController {
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}

struct EdgeGestureDeferringHost<Content: View>: UIViewControllerRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeUIViewController(context: Context) -> EdgeGestureDeferringViewController {
        let host = EdgeGestureDeferringViewController()
        let child = UIHostingController(rootView: content)
        child.view.backgroundColor = .clear
        host.addChild(child)
        host.view.addSubview(child.view)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: host.view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor)
        ])
        child.didMove(toParent: host)
        context.coordinator.child = child
        return host
    }

    func updateUIViewController(_ uiViewController: EdgeGestureDeferringViewController, context: Context) {
        context.coordinator.child?.rootView = content
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var child: UIHostingController<Content>?
    }
}
