import AVFoundation
import SwiftUI

/// Full-screen camera that reports the first QR code it sees. The QR on the
/// computer is the only way to pair, so this is the app's front door.
struct ScannerView: UIViewControllerRepresentable {
    let onCode: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        return c
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}
}

// @preconcurrency: the delegate protocol is nonisolated, but every call is
// made on the main queue (set below), so treating the conformance as
// main-actor is true — Swift just cannot see the queue.
final class ScannerController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onCode: (@MainActor (String) -> Void)?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            showUnavailable()
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showUnavailable()
            return
        }
        session.addOutput(output)
        // Delivered on main: the handler mutates UI state, and QR frames are
        // sparse enough that there is nothing to gain from another queue.
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        delivered = false
        // startRunning blocks for a few hundred milliseconds. Apple suggests a
        // background queue; under strict concurrency AVCaptureSession cannot
        // cross to one without an unsafe annotation, and the sheet is opening
        // anyway, so the hitch is hidden by the transition.
        if !session.isRunning { session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        // The camera keeps reporting the same code every frame it is in view;
        // one delivery per appearance is what the caller wants.
        guard !delivered,
              let object = objects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue
        else { return }
        delivered = true
        onCode?(value)
    }

    private func showUnavailable() {
        let label = UILabel()
        label.text = "No camera available."
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
