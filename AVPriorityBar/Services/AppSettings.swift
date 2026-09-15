import SwiftUI

/// User-facing options that aren't device priorities.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var mirrorPreview: Bool {
        didSet { defaults.set(mirrorPreview, forKey: "mirrorPreview") }
    }

    /// Closing the floating preview as soon as it loses focus makes it behave
    /// like a glance rather than a window to manage.
    @Published var closeMirrorOnFocusLoss: Bool {
        didSet { defaults.set(closeMirrorOnFocusLoss, forKey: "closeMirrorOnFocusLoss") }
    }

    @Published var showPreviewInPanel: Bool {
        didSet { defaults.set(showPreviewInPanel, forKey: "showPreviewInPanel") }
    }

    private init() {
        mirrorPreview = defaults.object(forKey: "mirrorPreview") as? Bool ?? true
        closeMirrorOnFocusLoss = defaults.object(forKey: "closeMirrorOnFocusLoss") as? Bool ?? true
        showPreviewInPanel = defaults.object(forKey: "showPreviewInPanel") as? Bool ?? true
    }
}
