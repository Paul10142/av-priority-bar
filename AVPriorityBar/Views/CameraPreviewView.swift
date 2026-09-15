import SwiftUI
import AVFoundation

/// Live thumbnail of one camera, so the right one can be confirmed at a glance.
///
/// This is the only place the app opens a video stream, which is also the only
/// time the green camera light comes on. The session runs while the camera
/// section is on screen and is torn down the moment it isn't.
@MainActor
final class CameraPreviewController: ObservableObject {
    @Published private(set) var session: AVCaptureSession?
    @Published private(set) var failed = false

    private var runningUniqueID: String?
    private let queue = DispatchQueue(label: "camera-preview")

    func start(uniqueID: String?) {
        guard let uniqueID else { stop(); return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            failed = true
            return
        }
        guard uniqueID != runningUniqueID else { return }
        stop()

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        )
        guard let device = discovery.devices.first(where: { $0.uniqueID == uniqueID }),
              let input = try? AVCaptureDeviceInput(device: device) else {
            failed = true
            return
        }

        let session = AVCaptureSession()
        session.sessionPreset = .low
        guard session.canAddInput(input) else {
            failed = true
            return
        }
        session.addInput(input)

        self.session = session
        self.runningUniqueID = uniqueID
        self.failed = false
        queue.async { session.startRunning() }
    }

    func stop() {
        guard let session else { return }
        self.session = nil
        self.runningUniqueID = nil
        queue.async { session.stopRunning() }
    }

    // No deinit teardown: the view's onDisappear stops the session, and a
    // deinit can't touch main-actor state anyway.
}

struct CameraPreviewLayerView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
    }

    final class PreviewNSView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            previewLayer.videoGravity = .resizeAspectFill
            layer = previewLayer
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }
}

/// The preview panel shown above the camera list: the live image plus the name
/// of whichever camera apps are currently getting.
struct CameraPreviewPanel: View {
    @EnvironmentObject var cameraManager: CameraManager
    @StateObject private var controller = CameraPreviewController()

    private var activeCamera: CameraDevice? {
        if let id = cameraManager.currentPreferredID,
           let match = cameraManager.cameras.first(where: { $0.uniqueID == id }) {
            return match
        }
        return cameraManager.topPriorityCamera
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.85))

                if let session = controller.session {
                    CameraPreviewLayerView(session: session)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: cameraManager.authState == .authorized ? "video.slash" : "lock")
                            .font(.system(size: 18))
                        Text(placeholderText)
                            .font(.system(size: 11))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.horizontal, 12)
                }
            }
            .frame(height: 150)

            HStack(spacing: 6) {
                if let camera = activeCamera {
                    Image(systemName: camera.kind.icon)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(camera.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("No camera selected")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if controller.session != nil {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("Live")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .onAppear { controller.start(uniqueID: activeCamera?.uniqueID) }
        .onDisappear { controller.stop() }
        .onChange(of: activeCamera?.uniqueID) { _, newValue in
            controller.start(uniqueID: newValue)
        }
    }

    private var placeholderText: String {
        switch cameraManager.authState {
        case .authorized:
            return controller.failed ? "This camera can't be previewed" : "No camera to preview"
        default:
            return "Allow camera access to see a preview"
        }
    }
}
