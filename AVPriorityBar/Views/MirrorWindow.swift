import AppKit
import SwiftUI
import AVFoundation

/// The floating camera window: a resizable, movable panel showing the active
/// camera, opened from the menu or a keyboard shortcut and closed by clicking
/// away from it.
@MainActor
final class MirrorWindowController: NSObject, NSWindowDelegate {
    static let shared = MirrorWindowController()

    private var window: NSPanel?
    private let controller = CameraPreviewController()
    private var cameraLookup: (() -> (id: String, name: String)?)?

    var isOpen: Bool { window?.isVisible ?? false }

    /// Told how to find the current camera rather than owning that decision.
    func configure(cameraProvider: @escaping () -> (id: String, name: String)?) {
        cameraLookup = cameraProvider
    }

    func toggle() {
        if isOpen { close() } else { show() }
    }

    func show() {
        let camera = cameraLookup?()
        let panel = window ?? makeWindow()
        window = panel

        controller.start(uniqueID: camera?.id)
        panel.title = camera?.name ?? "Camera"
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        controller.stop()
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.delegate = self
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: MirrorWindowContent(controller: controller)
        )
        panel.setFrameAutosaveName("AVPriorityBarMirror")
        if panel.frame.origin == .zero {
            positionNearMenuBar(panel)
        }
        return panel
    }

    /// Opens under the menu bar on the right, which is where the menu it belongs
    /// to lives.
    private func positionNearMenuBar(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - 16,
            y: visible.maxY - size.height - 8
        )
        panel.setFrameOrigin(origin)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard AppSettings.shared.closeMirrorOnFocusLoss else { return }
        close()
    }

    func windowWillClose(_ notification: Notification) {
        controller.stop()
    }
}

private struct MirrorWindowContent: View {
    @ObservedObject var controller: CameraPreviewController
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ZStack {
            Color.black
            if let session = controller.session {
                CameraPreviewLayerView(session: session, mirrored: settings.mirrorPreview)
            } else {
                Text("No camera")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .ignoresSafeArea()
    }
}
