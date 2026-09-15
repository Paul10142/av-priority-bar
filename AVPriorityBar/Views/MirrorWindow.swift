import AppKit
import SwiftUI
import AVFoundation

/// The floating camera window: resizable, movable, and opened from the menu, a
/// shortcut, or the notch.
@MainActor
final class MirrorWindowController: NSObject, NSWindowDelegate {
    static let shared = MirrorWindowController()

    private var window: NSPanel?
    private let controller = CameraPreviewController()
    private var cameraLookup: (() -> (id: String, name: String)?)?
    /// The menu bar popover is still key for a moment after this window opens,
    /// so close-on-focus-loss has to ignore that first handover or the window
    /// shuts itself the instant it appears.
    private var openedAt: Date?
    private var autoCloseWork: DispatchWorkItem?

    var isOpen: Bool { window?.isVisible ?? false }

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
        applySettings()
        openedAt = Date()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        scheduleAutoCloseIfNeeded()
    }

    /// Switches the live window to another camera without reopening it.
    func showCamera(uniqueID: String, name: String) {
        guard isOpen else { return }
        controller.start(uniqueID: uniqueID)
        window?.title = name
    }

    func close() {
        autoCloseWork?.cancel()
        autoCloseWork = nil
        controller.stop()
        window?.orderOut(nil)
    }

    /// Re-applies size, position and level after a settings change.
    func applySettings() {
        guard let panel = window else { return }
        let settings = AppSettings.shared
        panel.level = settings.keepWindowInFront ? .floating : .normal

        let width = CGFloat(settings.windowWidth)
        let height = (width * 3 / 4).rounded()
        if abs(panel.frame.width - width) > 1 {
            var frame = panel.frame
            // Grow from the top-left so the window doesn't crawl up the screen.
            frame.origin.y += frame.height - height
            frame.size = NSSize(width: width, height: height)
            panel.setFrame(frame, display: true)
        }
        position(panel)
    }

    private func position(_ panel: NSPanel) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let margin: CGFloat = 16

        let origin: NSPoint
        switch AppSettings.shared.windowPosition {
        case .remember:
            return
        case .topRight:
            origin = NSPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin)
        case .topLeft:
            origin = NSPoint(x: visible.minX + margin, y: visible.maxY - size.height - margin)
        case .center:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        case .underNotch:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 4)
        }
        panel.setFrameOrigin(origin)
    }

    private func makeWindow() -> NSPanel {
        let width = CGFloat(AppSettings.shared.windowWidth)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: (width * 3 / 4).rounded()),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.delegate = self
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: MirrorWindowContent(controller: controller))
        panel.setFrameAutosaveName("AVPriorityBarMirror")
        return panel
    }

    private func scheduleAutoCloseIfNeeded() {
        autoCloseWork?.cancel()
        guard AppSettings.shared.closeBehavior == .afterDelay else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.close() }
        }
        autoCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AppSettings.shared.closeDelaySeconds, execute: work)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard AppSettings.shared.closeBehavior == .onClickAway else { return }
        // Ignore the handover from the menu bar popover that opened us.
        if let openedAt, Date().timeIntervalSince(openedAt) < 0.8 { return }
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

/// An invisible click target over the notch. macOS reports the notch area as the
/// gap between the screen's full frame and its auxiliary top areas; a borderless
/// window sits there and forwards a click.
@MainActor
final class NotchClickController {
    static let shared = NotchClickController()

    private var window: NSWindow?

    func apply(enabled: Bool) {
        if enabled { install() } else { remove() }
    }

    private func install() {
        guard window == nil, let screen = NSScreen.main else { return }
        guard let notchRect = notchFrame(for: screen) else { return }

        let panel = NSPanel(contentRect: notchRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = NotchClickView()
        panel.orderFrontRegardless()
        window = panel
    }

    private func remove() {
        window?.orderOut(nil)
        window = nil
    }

    /// nil on a Mac without a notch, where this setting has nothing to attach to.
    private func notchFrame(for screen: NSScreen) -> NSRect? {
        let topInset = screen.safeAreaInsets.top
        guard topInset > 0 else { return nil }
        let notchWidth: CGFloat = 200
        return NSRect(
            x: screen.frame.midX - notchWidth / 2,
            y: screen.frame.maxY - topInset,
            width: notchWidth,
            height: topInset
        )
    }

    var isSupported: Bool {
        guard let screen = NSScreen.main else { return false }
        return screen.safeAreaInsets.top > 0
    }
}

private final class NotchClickView: NSView {
    override func mouseDown(with event: NSEvent) {
        Task { @MainActor in
            MirrorWindowController.shared.toggle()
        }
    }
}
