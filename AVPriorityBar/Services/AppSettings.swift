import SwiftUI

enum MirrorCloseBehavior: String, CaseIterable, Identifiable {
    case onClickAway
    case onEscapeOnly
    case afterDelay

    var id: String { rawValue }

    var label: String {
        switch self {
        case .onClickAway: return "When I click away"
        case .onEscapeOnly: return "Only when I close it"
        case .afterDelay: return "After a few seconds"
        }
    }
}

enum MirrorWindowPosition: String, CaseIterable, Identifiable {
    case remember
    case topRight
    case topLeft
    case center
    case underNotch
    case overMenuBarIcon

    var id: String { rawValue }

    var label: String {
        switch self {
        case .remember: return "Where I left it"
        case .topRight: return "Top right"
        case .topLeft: return "Top left"
        case .center: return "Centre"
        case .underNotch: return "Under the notch"
        case .overMenuBarIcon: return "Below the menu bar icon"
        }
    }
}

/// Everything that isn't a device priority.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var mirrorPreview: Bool { didSet { defaults.set(mirrorPreview, forKey: "mirrorPreview") } }
    @Published var showPreviewInPanel: Bool { didSet { defaults.set(showPreviewInPanel, forKey: "showPreviewInPanel") } }
    @Published var keepWindowInFront: Bool {
        didSet {
            defaults.set(keepWindowInFront, forKey: "keepWindowInFront")
            MirrorWindowController.shared.applySettings()
        }
    }
    @Published var windowWidth: Double {
        didSet {
            defaults.set(windowWidth, forKey: "mirrorWindowWidth")
            guard !isSyncingFromWindow else { return }
            MirrorWindowController.shared.applySettings()
        }
    }
    /// Set while the window itself reports a resize, so writing the new width
    /// back into settings doesn't bounce the window around.
    var isSyncingFromWindow = false
    @Published var closeBehavior: MirrorCloseBehavior {
        didSet { defaults.set(closeBehavior.rawValue, forKey: "mirrorCloseBehavior") }
    }
    @Published var closeDelaySeconds: Double {
        didSet { defaults.set(closeDelaySeconds, forKey: "mirrorCloseDelay") }
    }
    @Published var windowPosition: MirrorWindowPosition {
        didSet {
            defaults.set(windowPosition.rawValue, forKey: "mirrorWindowPosition")
            MirrorWindowController.shared.applySettings()
        }
    }
    /// A transparent click target sitting over the notch, so the camera is one
    /// flick of the pointer away.
    @Published var notchClickEnabled: Bool {
        didSet {
            defaults.set(notchClickEnabled, forKey: "notchClickEnabled")
            NotchClickController.shared.apply(enabled: notchClickEnabled)
        }
    }
    @Published var panelWidth: Double {
        didSet { defaults.set(panelWidth, forKey: "panelWidth") }
    }
    @Published var micCheckEnabled: Bool { didSet { defaults.set(micCheckEnabled, forKey: "micCheckEnabled") } }
    /// Opening the Camera tab pops the floating window as well.
    @Published var openWindowWithCameraTab: Bool {
        didSet { defaults.set(openWindowWithCameraTab, forKey: "openWindowWithCameraTab") }
    }

    private init() {
        mirrorPreview = defaults.object(forKey: "mirrorPreview") as? Bool ?? true
        showPreviewInPanel = defaults.object(forKey: "showPreviewInPanel") as? Bool ?? true
        keepWindowInFront = defaults.object(forKey: "keepWindowInFront") as? Bool ?? true
        windowWidth = defaults.object(forKey: "mirrorWindowWidth") as? Double ?? 360
        closeBehavior = MirrorCloseBehavior(rawValue: defaults.string(forKey: "mirrorCloseBehavior") ?? "") ?? .onClickAway
        closeDelaySeconds = defaults.object(forKey: "mirrorCloseDelay") as? Double ?? 5
        windowPosition = MirrorWindowPosition(rawValue: defaults.string(forKey: "mirrorWindowPosition") ?? "") ?? .remember
        notchClickEnabled = defaults.object(forKey: "notchClickEnabled") as? Bool ?? false
        panelWidth = defaults.object(forKey: "panelWidth") as? Double ?? 340
        micCheckEnabled = defaults.object(forKey: "micCheckEnabled") as? Bool ?? true
        openWindowWithCameraTab = defaults.object(forKey: "openWindowWithCameraTab") as? Bool ?? true
    }
}
