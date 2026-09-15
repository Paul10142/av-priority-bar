import SwiftUI
import CoreAudio
import AppKit

/// Height the panel gives its scrolling middle. The window is sized to fit its
/// content, so this has to be measured and clamped rather than left to grow.
private enum PanelMetrics {
    static let minContentHeight: CGFloat = 120
    /// Only a genuinely huge list should ever scroll; below this the panel just
    /// grows to fit whatever tab is showing.
    static let maxContentHeight: CGFloat = 640
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum PanelTab: String, CaseIterable {
    case audio
    case camera
    case settings

    /// Settings is reached from the gear in the footer, not from the tab row.
    static var tabBarCases: [PanelTab] { [.audio, .camera] }

    var label: String {
        switch self {
        case .audio: return "Audio"
        case .camera: return "Camera"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .audio: return "speaker.wave.2.fill"
        case .camera: return "camera.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var audioManager: AudioManager
    @EnvironmentObject var cameraManager: CameraManager
    @AppStorage("selectedTab") private var selectedTabRaw: String = PanelTab.audio.rawValue
    @State private var contentHeight: CGFloat = PanelMetrics.minContentHeight

    private var selectedTab: PanelTab {
        PanelTab(rawValue: selectedTabRaw) ?? .audio
    }

    /// The scroll area is given an explicit height so the menu bar window
    /// actually resizes when the content changes - left to itself it keeps
    /// whatever height it had when it first opened and clips the rest.
    private var scrollHeight: CGFloat {
        min(max(contentHeight, PanelMetrics.minContentHeight), PanelMetrics.maxContentHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            TabSwitcherView(selected: selectedTab) { tab in
                selectedTabRaw = tab.rawValue
                contentHeight = PanelMetrics.minContentHeight
                if tab == .camera {
                    cameraManager.requestAccessIfNeeded()
                    cameraManager.refreshCameras()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 12)

            ScrollView {
                Group {
                    switch selectedTab {
                    case .camera: CameraContentView()
                    case .settings: SettingsPageView()
                    case .audio: AudioContentView()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            .frame(height: scrollHeight)
            .onPreferenceChange(ContentHeightKey.self) { height in
                guard height > 0 else { return }
                contentHeight = height
            }

            Divider()
                .padding(.horizontal, 12)

            FooterView(tab: selectedTab)
        }
        .frame(width: 340)
    }
}

struct TabSwitcherView: View {
    let selected: PanelTab
    let onSelect: (PanelTab) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PanelTab.tabBarCases, id: \.self) { tab in
                let isSelected = tab == selected
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { onSelect(tab) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11))
                        Text(tab.label)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? Color.accentColor : Color.clear)
                    )
                    .foregroundColor(isSelected ? .white : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

struct FooterView: View {
    @EnvironmentObject var audioManager: AudioManager
    @EnvironmentObject var cameraManager: CameraManager
    let tab: PanelTab

    private var isEditing: Bool {
        tab == .camera ? cameraManager.isEditMode : audioManager.isEditMode
    }

    private var showsEdit: Bool { tab != .settings }

    var body: some View {
        HStack(spacing: 16) {
            if tab == .audio && !audioManager.isEditMode {
                HiddenDevicesToggleView()
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            Spacer()

            SettingsGearButton()

            if showsEdit {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if tab == .camera {
                        cameraManager.toggleEditMode()
                    } else {
                        audioManager.toggleEditMode()
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isEditing ? "checkmark.circle.fill" : "pencil.circle")
                        .font(.system(size: 12))
                    Text(isEditing ? "Done" : "Edit")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(isEditing ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(tab == .camera ? "Show every camera ever connected" : "Show every audio device ever connected")
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                    Text("Quit App")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit AV Priority Bar")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(.easeInOut(duration: 0.2), value: isEditing)
    }
}

/// All three audio sections at once, each with its own volume control sitting
/// directly under the list it belongs to.
struct AudioContentView: View {
    @EnvironmentObject var audioManager: AudioManager

    private var activeSpeaker: AudioDevice? {
        audioManager.speakerDevices.first { $0.id == audioManager.currentOutputId }
    }

    private var activeHeadphone: AudioDevice? {
        audioManager.headphoneDevices.first { $0.id == audioManager.currentOutputId }
    }

    private var activeMicrophone: AudioDevice? {
        audioManager.inputDevices.first { $0.id == audioManager.currentInputId }
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                DeviceVolumeSliderView(device: activeSpeaker, fallbackIcon: "speaker.wave.2.fill")
                DeviceVolumeSliderView(device: activeHeadphone, fallbackIcon: "headphones")
            }

            DeviceSectionView(
                title: "Speakers",
                icon: "speaker.wave.2.fill",
                devices: audioManager.speakerDevices,
                currentDeviceId: audioManager.currentOutputId,
                onMove: audioManager.moveSpeakerDevice,
                onSelect: { device in
                    audioManager.setMode(.speaker)
                    audioManager.setOutputDevice(device)
                },
                onHide: { audioManager.hideDevice($0, category: .speaker) },
                onUnhide: { audioManager.unhideDevice($0, category: .speaker) },
                category: .speaker,
                showCategoryPicker: true,
                isActiveCategory: audioManager.currentMode == .speaker
            )

            DeviceSectionView(
                title: "Headphones",
                icon: "headphones",
                devices: audioManager.headphoneDevices,
                currentDeviceId: audioManager.currentOutputId,
                onMove: audioManager.moveHeadphoneDevice,
                onSelect: { device in
                    audioManager.setMode(.headphone)
                    audioManager.setOutputDevice(device)
                },
                onHide: { audioManager.hideDevice($0, category: .headphone) },
                onUnhide: { audioManager.unhideDevice($0, category: .headphone) },
                category: .headphone,
                showCategoryPicker: true,
                isActiveCategory: audioManager.currentMode == .headphone
            )

            VStack(spacing: 10) {
                DeviceSectionView(
                    title: "Microphones",
                    icon: "mic.fill",
                    devices: audioManager.inputDevices,
                    currentDeviceId: audioManager.currentInputId,
                    onMove: audioManager.moveInputDevice,
                    onSelect: audioManager.setInputDevice,
                    onHide: { audioManager.hideDevice($0, category: nil) },
                    onUnhide: { audioManager.unhideDevice($0, category: nil) },
                    category: nil,
                    showCategoryPicker: false
                )
                DeviceVolumeSliderView(device: activeMicrophone, fallbackIcon: "mic.fill")
            }
        }
    }
}

/// Volume for one specific device - the one currently in use in that section.
/// Hidden entirely for devices that expose no volume control, rather than
/// showing a slider that does nothing.
struct DeviceVolumeSliderView: View {
    @EnvironmentObject var audioManager: AudioManager
    let device: AudioDevice?
    let fallbackIcon: String

    private var isMuted: Bool {
        guard let device else { return false }
        return audioManager.isDeviceMuted(device)
    }

    private var level: Float {
        guard let device else { return 0 }
        return audioManager.volume(for: device)
    }

    var body: some View {
        if let device, audioManager.hasVolumeControl(device) {
            HStack(spacing: 10) {
                Button {
                    audioManager.toggleMute(device)
                } label: {
                    Image(systemName: isMuted ? mutedIcon : fallbackIcon)
                        .font(.system(size: 12))
                        .foregroundColor(isMuted ? .red : .accentColor)
                        .frame(width: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isMuted ? "Unmute \(device.name)" : "Mute \(device.name)")

                Slider(
                    value: Binding(
                        get: { Double(level) },
                        set: {
                        if isMuted { audioManager.toggleMute(device) }
                        audioManager.setVolume(Float($0), for: device)
                    }
                    ),
                    in: 0...1
                )
                .controlSize(.small)

                Text("\(Int(level * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            .padding(.leading, 8)
            .onScrollWheel { delta in
                audioManager.setVolume(level + Float(delta * 0.02), for: device)
            }
        }
    }

    private var mutedIcon: String {
        device?.type == .input ? "mic.slash.fill" : "speaker.slash.fill"
    }
}

// Scroll wheel modifier
struct ScrollWheelModifier: ViewModifier {
    let onScroll: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content.background(
            ScrollWheelReceiver(onScroll: onScroll)
        )
    }
}

struct ScrollWheelReceiver: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
    }
}

class ScrollWheelNSView: NSView {
    var onScroll: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.deltaY)
    }
}

extension View {
    func onScrollWheel(_ action: @escaping (CGFloat) -> Void) -> some View {
        modifier(ScrollWheelModifier(onScroll: action))
    }
}

struct DeviceSectionView: View {
    let title: String
    let icon: String
    let devices: [AudioDevice]
    let currentDeviceId: AudioObjectID?
    let onMove: (IndexSet, Int) -> Void
    let onSelect: (AudioDevice) -> Void
    var onHide: ((AudioDevice) -> Void)?
    var onUnhide: ((AudioDevice) -> Void)?
    var category: OutputCategory?
    var showCategoryPicker: Bool = false
    var isActiveCategory: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(isActiveCategory ? .accentColor : .secondary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }

            if devices.isEmpty {
                Text("No devices")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary.opacity(0.7))
                    .italic()
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                DeviceListView(
                    devices: devices,
                    currentDeviceId: currentDeviceId,
                    onMove: onMove,
                    onSelect: onSelect,
                    showCategoryPicker: showCategoryPicker,
                    onHide: onHide,
                    onUnhide: onUnhide,
                    category: category
                )
            }
        }
    }
}

struct HiddenDevicesToggleView: View {
    @EnvironmentObject var audioManager: AudioManager
    @State private var isExpanded = false

    var allHiddenDevices: [AudioDevice] {
        audioManager.hiddenInputDevices +
        audioManager.hiddenSpeakerDevices +
        audioManager.hiddenHeadphoneDevices
    }

    var body: some View {
        if allHiddenDevices.isEmpty {
            Text("")
                .frame(height: 1)
        } else {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: "eye.slash")
                        .font(.system(size: 11))
                    Text("\(allHiddenDevices.count) ignored")
                        .font(.system(size: 12))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isExpanded, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(allHiddenDevices, id: \.id) { device in
                        HiddenDeviceRow(device: device)
                    }
                }
                .padding(12)
                .frame(minWidth: 220)
            }
        }
    }
}

struct HiddenDeviceRow: View {
    @EnvironmentObject var audioManager: AudioManager
    let device: AudioDevice
    @State private var isHovering = false

    var deviceIcon: String {
        if device.type == .input {
            return "mic.fill"
        } else {
            let category = audioManager.priorityManager.getCategory(for: device)
            return category == .headphone ? "headphones" : "speaker.wave.2.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: deviceIcon)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 18)

            Text(device.name)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if isHovering {
                Button {
                    audioManager.unhideDevice(device)
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop ignoring")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

struct LaunchAtLoginToggle: View {
    @StateObject private var launchManager = LaunchAtLoginManager.shared
    
    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                launchManager.isEnabled.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: launchManager.isEnabled ? "power.circle.fill" : "power.circle")
                    .font(.system(size: 12))
                Text("Login")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(launchManager.isEnabled ? .accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help(launchManager.isEnabled ? "Disable launch at login" : "Enable launch at login")
    }
}

/// Gear in the footer: swaps the panel to Settings and back to where you were.
struct SettingsGearButton: View {
    @AppStorage("selectedTab") private var selectedTabRaw: String = PanelTab.audio.rawValue
    @AppStorage("tabBeforeSettings") private var previousTabRaw: String = PanelTab.audio.rawValue

    private var isShowingSettings: Bool { selectedTabRaw == PanelTab.settings.rawValue }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isShowingSettings {
                    selectedTabRaw = previousTabRaw
                } else {
                    previousTabRaw = selectedTabRaw
                    selectedTabRaw = PanelTab.settings.rawValue
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isShowingSettings ? "chevron.backward" : "gearshape")
                    .font(.system(size: 12))
                Text(isShowingSettings ? "Back" : "Settings")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isShowingSettings ? .accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}
