import AppKit
import SwiftUI
import Combine

/// Owns the menu bar item and the panel that drops from it.
///
/// This replaces SwiftUI's MenuBarExtra, which always drops straight under its
/// icon at a size it decides. Running the panel as a window of our own is what
/// makes "open in the top right corner" and an adjustable width possible.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let shared = PanelController()

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var scrollView: NSScrollView?
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    private let audioManager = AudioManager.shared
    private let cameraManager = CameraManager.shared

    var isOpen: Bool { panel?.isVisible ?? false }

    // MARK: - Menu bar item

    func install() {
        // Smoke test hook: lets a build be launched with the panel already open,
        // so "does it survive being shown?" can be checked without a click.
        if ProcessInfo.processInfo.environment["AVPB_AUTO_OPEN_PANEL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                Task { @MainActor in self?.open() }
            }
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        statusItem = item
        updateStatusItemImage()

        // Redraw the icon whenever mute, volume or output mode changes.
        Publishers.CombineLatest4(
            audioManager.$volume,
            audioManager.$isActiveOutputMuted,
            audioManager.$isActiveInputMuted,
            audioManager.$currentMode
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _, _ in
            self?.updateStatusItemImage()
        }
        .store(in: &cancellables)
    }

    /// One symbol, always one glyph wide, so the rest of the menu bar never moves.
    private func updateStatusItemImage() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        if audioManager.isActiveOutputMuted {
            symbol = "speaker.slash.fill"
        } else if audioManager.isActiveInputMuted {
            symbol = "mic.slash.fill"
        } else if audioManager.currentMode == .headphone {
            symbol = "headphones"
        } else {
            symbol = "speaker.wave.3.fill"
        }

        let image: NSImage?
        if symbol == "speaker.wave.3.fill" {
            image = NSImage(
                systemSymbolName: symbol,
                variableValue: Double(audioManager.volume),
                accessibilityDescription: "AV Priority Bar"
            )
        } else {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AV Priority Bar")
        }
        image?.isTemplate = true
        button.image = image
    }

    @objc private func statusItemClicked() {
        toggle()
    }

    // MARK: - Panel

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        let panel = panel ?? makePanel()
        self.panel = panel

        resizeToFitContent()
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startMonitoring()

        if AppSettings.shared.openWindowWithCameraTab,
           UserDefaults.standard.string(forKey: "selectedTab") == PanelTab.camera.rawValue {
            MirrorWindowController.shared.show()
        }
    }

    func close() {
        stopMonitoring()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let width = CGFloat(AppSettings.shared.panelWidth)
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let root = AnyView(
            MenuBarView()
                .environmentObject(audioManager)
                .environmentObject(cameraManager)
        )

        // The SwiftUI view is the scroll view's document, so its height is its
        // own business. Letting the window size drive the content's height and
        // the content's height drive the window size is a layout loop, and
        // SwiftUI resolves that loop by overflowing the stack.
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: hosting.intrinsicContentSize.height)
        hosting.postsFrameChangedNotifications = true
        hostingView = hosting

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = hosting
        scroll.automaticallyAdjustsContentInsets = false
        scrollView = scroll

        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.addSubview(scroll)
        scroll.frame = background.bounds
        scroll.autoresizingMask = [.width, .height]
        panel.contentView = background

        NotificationCenter.default.addObserver(
            self, selector: #selector(contentSizeChanged),
            name: NSView.frameDidChangeNotification, object: hosting
        )
        return panel
    }

    @objc private func contentSizeChanged() {
        resizeToFitContent()
    }

    /// Window height follows the content, clamped to what the screen can show.
    private func resizeToFitContent() {
        guard let panel, let hosting = hostingView else { return }
        let width = CGFloat(AppSettings.shared.panelWidth)
        let screenLimit = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let maxHeight = min(PanelMetrics.maxContentHeight, screenLimit - 40)
        let contentHeight = max(hosting.intrinsicContentSize.height, 120)
        let height = min(contentHeight, maxHeight)

        if abs(hosting.frame.width - width) > 1 || abs(hosting.frame.height - contentHeight) > 1 {
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        }
        guard abs(panel.frame.height - height) > 1 || abs(panel.frame.width - width) > 1 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: width, height: height)
        panel.setFrame(frame, display: true)
    }

    /// Under the menu bar icon, or pinned to the top right - the icon's own
    /// window frame is what makes the first one land in the right place.
    private func position(_ panel: NSPanel) {
        guard let screen = statusItem?.button?.window?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let margin: CGFloat = 8

        var origin = NSPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin)
        if AppSettings.shared.panelPosition == .underIcon,
           let buttonWindow = statusItem?.button?.window {
            let buttonFrame = buttonWindow.frame
            let x = min(max(buttonFrame.midX - size.width / 2, visible.minX + margin), visible.maxX - size.width - margin)
            origin = NSPoint(x: x, y: buttonFrame.minY - size.height - 2)
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: - Dismissal

    private func startMonitoring() {
        stopMonitoring()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // 53 is Escape. Recording a shortcut needs the key itself, so the
            // hot key recorder gets first refusal.
            guard event.keyCode == 53, !HotKeyManager.shared.isRecording else { return event }
            Task { @MainActor in self?.close() }
            return nil
        }
    }

    private func stopMonitoring() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        outsideClickMonitor = nil
        escapeMonitor = nil
    }

    /// Called when the width setting changes while the panel is open.
    func applySettings() {
        guard let panel, panel.isVisible else { return }
        resizeToFitContent()
        position(panel)
    }
}

/// A borderless panel still has to be able to take key focus, otherwise sliders
/// and the shortcut recorder don't respond.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
