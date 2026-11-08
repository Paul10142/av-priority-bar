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
    /// Where the menu bar panel was last opened, used to put the window under
    /// the menu bar icon - AppKit doesn't hand out a MenuBarExtra's frame.
    var lastMenuBarPoint: NSPoint?
    /// True while the controller is moving the window itself, so its own moves
    /// aren't mistaken for the user dragging it.
    private var isPositioning = false

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
        // Only resize when the setting actually changed; otherwise a window the
        // user dragged bigger would snap back every time it opened.
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
        case .overMenuBarIcon:
            let anchorX = lastMenuBarPoint?.x ?? (visible.maxX - size.width / 2 - margin)
            let clampedX = min(max(anchorX - size.width / 2, visible.minX + margin), visible.maxX - size.width - margin)
            origin = NSPoint(x: clampedX, y: visible.maxY - size.height - 4)
        }
        isPositioning = true
        panel.setFrameOrigin(origin)
        DispatchQueue.main.async { [weak self] in self?.isPositioning = false }
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

    /// A drag on the window's corner is the user setting the size, so it is
    /// written back into settings rather than fought with.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window else { return }
        let settings = AppSettings.shared
        settings.isSyncingFromWindow = true
        settings.windowWidth = Double(window.frame.width)
        settings.isSyncingFromWindow = false
    }

    func windowDidMove(_ notification: Notification) {
        // Dragging it by hand means "remember this spot" - but only a drag.
        guard !isPositioning, window?.inLiveResize == false else { return }
        if AppSettings.shared.windowPosition != .remember {
            AppSettings.shared.windowPosition = .remember
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard AppSettings.shared.closeBehavior == .onClickAway else { return }
        // Ignore the handover from the menu bar popover that opened us.
        if let openedAt, Date().timeIntervalSince(openedAt) < 0.8 { return }
        // Opening this app's own menu is not "clicking away" - the window has
        // to survive you going back to the panel to change a setting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let ourWindowIsKey = NSApp.keyWindow != nil
            guard !ourWindowIsKey else { return }
            self.close()
        }
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
///
/// The strip is re-anchored every time the screen layout changes. Left where it
/// was created, a lid closing, a monitor coming or going, or mirroring to a
/// display of another height moves it, and after a few days of docking it sits
/// somewhere in the middle of the screen as an invisible click-swallower that
/// opens the camera (found 2026-11-08 at the bottom centre of the built-in
/// display, twelve days after launch).
@MainActor
final class NotchClickController {
    static let shared = NotchClickController()

    private var window: NSPanel?
    private var enabled = false
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var pendingReanchor: DispatchWorkItem?
    private let notchWidth: CGFloat = 200

    func apply(enabled: Bool) {
        self.enabled = enabled
        if enabled {
            startObserving()
            reanchor()
        } else {
            stopObserving()
            window?.orderOut(nil)
            window = nil
        }
    }

    /// True when some attached display has a notch to sit over.
    var isSupported: Bool { notchScreen != nil }

    /// The display that physically has a notch. There is at most one, and it is
    /// not always the main screen: an external monitor can hold the menu bar.
    private var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    /// Where the strip belongs right now, or nil when no screen has a notch
    /// (external display only, clamshell, mirroring).
    private var targetFrame: NSRect? {
        guard let screen = notchScreen else { return nil }
        return notchFrame(for: screen)
    }

    /// Whether this window is the strip, sitting over the notch, and so may act
    /// on a click. A strip that has drifted must swallow nothing.
    func isOverNotch(_ candidate: NSWindow?) -> Bool {
        guard let candidate, candidate === window, let target = targetFrame else { return false }
        let frame = candidate.frame
        return abs(frame.minX - target.minX) < 1 && abs(frame.minY - target.minY) < 1
            && abs(frame.width - target.width) < 1 && abs(frame.height - target.height) < 1
    }

    /// Puts the strip over the notch, or hides it when there is none.
    func reanchor() {
        guard enabled else { return }
        guard let target = targetFrame else {
            window?.orderOut(nil)
            return
        }
        let panel = window ?? makePanel(frame: target)
        window = panel
        if panel.frame != target {
            panel.setFrame(target, display: false)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func startObserving() {
        guard observers.isEmpty else { return }
        let app = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let token = app.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenLayoutChanged() }
        }
        observers.append((center: app, token: token))
        let wakeToken = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenLayoutChanged() }
        }
        observers.append((center: workspace, token: wakeToken))
    }

    private func stopObserving() {
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers.removeAll()
        pendingReanchor?.cancel()
        pendingReanchor = nil
    }

    /// Displays settle in steps (the lid, then the arrangement, then the
    /// resolution), and AppKit may still move windows after the first notice,
    /// so the strip is anchored at once and again a moment later.
    private func screenLayoutChanged() {
        reanchor()
        pendingReanchor?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.reanchor() }
        }
        pendingReanchor = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func makePanel(frame: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = NotchClickView()
        return panel
    }

    /// nil on a screen without a notch, where there is nothing to attach to.
    private func notchFrame(for screen: NSScreen) -> NSRect? {
        let topInset = screen.safeAreaInsets.top
        guard topInset > 0 else { return nil }
        return NSRect(
            x: screen.frame.midX - notchWidth / 2,
            y: screen.frame.maxY - topInset,
            width: notchWidth,
            height: topInset
        )
    }
}

private final class NotchClickView: NSView {
    override func mouseDown(with event: NSEvent) {
        let window = self.window
        Task { @MainActor in
            // A strip that has drifted off the notch must not open anything;
            // the click puts it back where it belongs instead.
            guard NotchClickController.shared.isOverNotch(window) else {
                NotchClickController.shared.reanchor()
                return
            }
            MirrorWindowController.shared.toggle()
        }
    }
}
