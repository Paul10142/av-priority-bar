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
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    private let audioManager = AudioManager.shared
    private let cameraManager = CameraManager.shared

    var isOpen: Bool { panel?.isVisible ?? false }

    // MARK: - Menu bar item

    func install() {
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

        applyWidth(to: panel)
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
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: AppSettings.shared.panelWidth, height: 200),
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

        let root = MenuBarView()
            .environmentObject(audioManager)
            .environmentObject(cameraManager)
            .background(PanelBackground())

        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
        return panel
    }

    private func applyWidth(to panel: NSPanel) {
        var frame = panel.frame
        let width = CGFloat(AppSettings.shared.panelWidth)
        guard abs(frame.width - width) > 1 else { return }
        frame.size.width = width
        panel.setFrame(frame, display: false)
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
        applyWidth(to: panel)
        position(panel)
    }
}

/// A borderless panel still has to be able to take key focus, otherwise sliders
/// and the shortcut recorder don't respond.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The rounded, blurred backing the system would have drawn for a menu.
private struct PanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
