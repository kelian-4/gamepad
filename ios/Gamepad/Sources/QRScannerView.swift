import SwiftUI
import VisionKit
import AVFoundation

enum PairingURL {
    static let defaultPort: UInt16 = 8765

    static func parse(_ text: String) -> (host: String, port: UInt16, secret: String?)? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "gamepad",
              let host = url.host, !host.isEmpty else { return nil }
        let secret = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "s" })?
            .value
        if let rawPort = url.port {
            guard let port = UInt16(exactly: rawPort) else { return nil }
            return (host, port, secret)
        }
        return (host, defaultPort, secret)
    }
}

struct QRScannerView: View {
    let onScan: (String, UInt16, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var access: Access = .checking
    @State private var invalidCode = false
    @State private var finished = false

    private enum Access {
        case checking
        case ready
        case unsupported
        case denied
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            switch access {
            case .checking:
                ProgressView().tint(.white)
            case .ready:
                DataScannerRepresentable(onCode: handle)
                    .ignoresSafeArea()
                if invalidCode {
                    Text("Ce QR code n'est pas celui d'un serveur Gamepad.")
                        .font(.footnote)
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding(.bottom, 80)
                }
            case .unsupported:
                message("Le scan de QR code n'est pas disponible sur cet appareil. Saisis l'adresse à la main.")
            case .denied:
                message("L'accès à la caméra est refusé. Autorise-le dans Réglages > Gamepad > Appareil photo.")
            }

            VStack {
                HStack {
                    Spacer()
                    Button("Fermer") { dismiss() }
                        .padding(12)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding()
                Spacer()
            }
        }
        .task { await prepare() }
    }

    private func message(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundColor(.white)
                .padding(32)
            Spacer()
        }
    }

    private func prepare() async {
        guard DataScannerViewController.isSupported else {
            access = .unsupported
            return
        }
        var status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            status = AVCaptureDevice.authorizationStatus(for: .video)
        }
        guard status == .authorized else {
            access = .denied
            return
        }
        access = DataScannerViewController.isAvailable ? .ready : .unsupported
    }

    private func handle(_ code: String) {
        guard !finished else { return }
        guard let target = PairingURL.parse(code) else {
            invalidCode = true
            return
        }
        finished = true
        onScan(target.host, target.port, target.secret)
        dismiss()
    }
}

private struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        DispatchQueue.main.async {
            try? controller.startScanning()
        }
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    onCode(payload)
                }
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                onCode(payload)
            }
        }
    }
}
