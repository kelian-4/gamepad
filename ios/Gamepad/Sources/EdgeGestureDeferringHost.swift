import SwiftUI
import UIKit

final class EdgeGestureDeferringViewController: UIViewController {
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    var childContentView: UIView?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        childContentView?.frame = view.bounds
    }
}

struct EdgeGestureDeferringHost<Content: View>: UIViewControllerRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeUIViewController(context: Context) -> EdgeGestureDeferringViewController {
        let host = EdgeGestureDeferringViewController()
        let child = UIHostingController(rootView: content)
        if #available(iOS 16.4, *) {
            child.safeAreaRegions = []
        }
        child.view.backgroundColor = .clear
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addChild(child)
        host.view.addSubview(child.view)
        child.view.frame = host.view.bounds
        host.childContentView = child.view
        child.didMove(toParent: host)
        context.coordinator.child = child
        return host
    }

    func updateUIViewController(_ uiViewController: EdgeGestureDeferringViewController, context: Context) {
        context.coordinator.child?.rootView = content
        uiViewController.childContentView?.frame = uiViewController.view.bounds
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var child: UIHostingController<Content>?
    }
}
