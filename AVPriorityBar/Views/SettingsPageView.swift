import SwiftUI

/// Settings, shown in place of the device lists rather than in a separate
/// window - a menu bar app with a settings window to hunt for is worse.
struct SettingsPageView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var hotKey = HotKeyManager.shared
    @StateObject private var launchManager = LaunchAtLoginManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            group("This menu") {
                SettingsRow(label: "Opens at") {
                    Picker("", selection: $settings.panelPosition) {
                        ForEach(PanelPosition.allCases) { position in
                            Text(position.label).tag(position)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                SettingsRow(label: "Width") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.panelWidth, in: 300...560, step: 10)
                            .controlSize(.small)
                        Text("\(Int(settings.panelWidth))pt")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            }

            group("Camera window") {
                SettingsToggleRow(title: "Mirror the image", isOn: $settings.mirrorPreview)
                SettingsToggleRow(title: "Keep in front of other windows", isOn: $settings.keepWindowInFront)

                SettingsRow(label: "Size") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.windowWidth, in: 220...900, step: 20)
                            .controlSize(.small)
                        Text("\(Int(settings.windowWidth))pt")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                }

                SettingsRow(label: "Opens at") {
                    Picker("", selection: $settings.windowPosition) {
                        ForEach(MirrorWindowPosition.allCases) { position in
                            Text(position.label).tag(position)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }

                SettingsRow(label: "Closes") {
                    Picker("", selection: $settings.closeBehavior) {
                        ForEach(MirrorCloseBehavior.allCases) { behavior in
                            Text(behavior.label).tag(behavior)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }

                if settings.closeBehavior == .afterDelay {
                    SettingsRow(label: "After") {
                        HStack(spacing: 8) {
                            Slider(value: $settings.closeDelaySeconds, in: 2...30, step: 1)
                                .controlSize(.small)
                            Text("\(Int(settings.closeDelaySeconds))s")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 46, alignment: .trailing)
                        }
                    }
                }

                Button {
                    MirrorWindowController.shared.show()
                } label: {
                    Label("Open camera window now", systemImage: "macwindow")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }

            group("Opening it") {
                SettingsRow(label: "Shortcut") {
                    HStack(spacing: 8) {
                        // The box itself starts recording - reaching for a
                        // separate Record button first is a step nobody expects.
                        Button {
                            if hotKey.isRecording {
                                hotKey.stopRecording()
                            } else {
                                hotKey.startRecording()
                            }
                        } label: {
                            Text(hotKey.isRecording ? "Press keys…" : hotKey.displayString)
                                .font(.system(size: 14, weight: .medium))
                                .tracking(2)
                                .foregroundColor(hotKey.isRecording ? .accentColor : .primary)
                                .frame(minWidth: 96, alignment: .center)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(Color.primary.opacity(hotKey.isRecording ? 0.12 : 0.06))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(hotKey.isRecording ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Click, then press the keys you want")

                        if hotKey.isRecording {
                            Button("Cancel") { hotKey.stopRecording() }.controlSize(.small)
                        } else if hotKey.displayString != "None" {
                            Button("Clear") { hotKey.clear() }.controlSize(.small)
                        }
                    }
                }

                if hotKey.registrationFailed {
                    Text("Another app already owns that combination - pick a different one.")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if NotchClickController.shared.isSupported {
                    SettingsToggleRow(
                        title: "Click the notch to open it",
                        detail: "Puts an invisible click target over the notch.",
                        isOn: $settings.notchClickEnabled
                    )
                }
            }

            group("App") {
                SettingsToggleRow(title: "Preview inside this menu", isOn: $settings.showPreviewInPanel)
                SettingsToggleRow(
                    title: "Open the window with the Camera tab",
                    detail: "The floating window appears whenever you open Camera.",
                    isOn: $settings.openWindowWithCameraTab
                )
                SettingsToggleRow(title: "Microphone check in the audio tab", isOn: $settings.micCheckEnabled)
                SettingsToggleRow(
                    title: "Launch at login",
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
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            content()
        }
    }
}

struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 60, alignment: .leading)
            content
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}
