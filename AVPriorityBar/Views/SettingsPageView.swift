import SwiftUI

/// Settings, shown in place of the device lists rather than in a separate
/// window - a menu bar app with a settings window to hunt for is worse.
struct SettingsPageView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var hotKey = HotKeyManager.shared
    @StateObject private var launchManager = LaunchAtLoginManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Camera window") {
                SettingsToggleRow(
                    title: "Mirror the image",
                    detail: "Show yourself the way a mirror would, not the way the camera sees you.",
                    isOn: $settings.mirrorPreview
                )
                SettingsToggleRow(
                    title: "Close when I click away",
                    detail: "The window disappears as soon as it loses focus.",
                    isOn: $settings.closeMirrorOnFocusLoss
                )
                Button {
                    MirrorWindowController.shared.show()
                } label: {
                    Label("Open camera window now", systemImage: "macwindow")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }

            group("Keyboard shortcut") {
                HStack(spacing: 10) {
                    Text(hotKey.isRecording ? "Press any combination…" : hotKey.displayString)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(hotKey.isRecording ? .accentColor : .primary)
                        .frame(minWidth: 90, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.06))
                        )

                    if hotKey.isRecording {
                        Button("Cancel") { hotKey.stopRecording() }
                            .controlSize(.small)
                    } else {
                        Button("Record") { hotKey.startRecording() }
                            .controlSize(.small)
                        Button("Clear") { hotKey.clear() }
                            .controlSize(.small)
                    }
                }
                Text("Opens and closes the camera window from anywhere. Needs at least one modifier key.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            group("Panel") {
                SettingsToggleRow(
                    title: "Preview inside this menu",
                    detail: "Turn off if you only want the floating window.",
                    isOn: $settings.showPreviewInPanel
                )
                SettingsToggleRow(
                    title: "Launch at login",
                    detail: "Start AV Priority Bar when you log in.",
                    isOn: Binding(
                        get: { launchManager.isEnabled },
                        set: { launchManager.isEnabled = $0 }
                    )
                )
            }
        }
        .onDisappear { hotKey.stopRecording() }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            content()
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}
