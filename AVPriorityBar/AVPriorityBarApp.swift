import SwiftUI
import AppKit
import CoreAudio

/// Wires up everything that has to exist before any menu is opened.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A menu bar app has no windows by design. Without this, the app quits the
    /// moment it notices that - taking the menu bar icon with it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// macOS asks a menu bar app to quit when its item is removed from the menu
    /// bar - and when Control Center refuses to place the item at all, that
    /// request arrives moments after launch, so the app dies silently with
    /// nothing in the logs. Quitting is the user's decision, not the menu bar's:
    /// an unrequested terminate in the first seconds is declined, which keeps
    /// the app alive and its keyboard shortcut working even with no icon.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppDelegate.quitRequestedByUser { return .terminateNow }
        if Date().timeIntervalSince(launchedAt) < 15 { return .terminateCancel }
        return .terminateNow
    }

    static var quitRequestedByUser = false
    private let launchedAt = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app owns no windows, and macOS treats a windowless app as
        // disposable: under memory pressure it automatically terminates it,
        // taking the menu bar icon with it. Both terminations have to be
        // declined explicitly, or the app quietly disappears minutes after
        // launch with nothing in the crash logs.
        ProcessInfo.processInfo.disableAutomaticTermination("Menu bar app with no windows")
        ProcessInfo.processInfo.disableSuddenTermination()

        NSApp.setActivationPolicy(.accessory)

        Task { @MainActor in
            SettingsMigration.runIfNeeded()
            PanelController.shared.install()

            MirrorWindowController.shared.configure {
                let manager = CameraManager.shared
                let preferred = manager.selectedCameraID ?? manager.currentPreferredID
                guard let id = preferred ?? manager.topPriorityCamera?.uniqueID else { return nil }
                let name = manager.cameras.first { $0.uniqueID == id }?.name ?? "Camera"
                return (id: id, name: name)
            }
            HotKeyManager.shared.onTrigger = {
                MirrorWindowController.shared.toggle()
            }
            HotKeyManager.shared.registerStoredHotKey()
            NotchClickController.shared.apply(enabled: AppSettings.shared.notchClickEnabled)
        }
    }
}

/// AppKit owns the menu bar item and the panel. SwiftUI's MenuBarExtra quits
/// the whole app when macOS declines to place its item, which fails silently and
/// can't be recovered from inside the app.
@main
enum AVPriorityBarMain {
    static func main() {
        // A brand-new status item is dropped at the far left of the menu bar -
        // exactly where menu bar managers like Ice keep their hidden section, so
        // the icon exists and nobody can see it. (Cadence solves it the same way.)
        //
        // The number is a distance leftwards from the right-hand end of the bar,
        // so a *smaller* value sits further right, and it has to stay clear of
        // the hidden section. A manager's divider is itself just an item with a
        // position: Ice's sits at 453 on the machine this was written for, and
        // the 460 used here previously landed seven units the wrong side of it,
        // hiding the icon it was meant to reveal.
        let positionKey = "NSStatusItem Preferred Position Item-0"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(320, forKey: positionKey)
        }
        // This app is nothing but its menu bar icon, so a stored "removed from
        // the menu bar" flag would leave it running with no way to reach it.
        UserDefaults.standard.set(true, forKey: "NSStatusItem VisibleCC Item-0")

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
class AudioManager: ObservableObject {
    /// Shared so the menu bar icon can track it without a view in between.
    static let shared = AudioManager()

    @Published var inputDevices: [AudioDevice] = []
    @Published var speakerDevices: [AudioDevice] = []
    @Published var headphoneDevices: [AudioDevice] = []
    @Published var hiddenInputDevices: [AudioDevice] = []
    @Published var hiddenSpeakerDevices: [AudioDevice] = []
    @Published var hiddenHeadphoneDevices: [AudioDevice] = []
    @Published var currentInputId: AudioObjectID?
    @Published var currentOutputId: AudioObjectID?
    @Published var currentMode: OutputCategory = .speaker
    @Published var volume: Float = 0
    @Published var isEditMode: Bool = false
    @Published var mutedDeviceIds: Set<AudioObjectID> = []
    @Published var isActiveOutputMuted: Bool = false
    @Published var isActiveInputMuted: Bool = false
    @Published var micFlashState: Bool = false
    @Published var deviceVolumes: [AudioObjectID: Float] = [:]

    private let deviceService = AudioDeviceService()
    private var micFlashTimer: Timer?
    let priorityManager = PriorityManager()
    private var connectedDeviceUIDs: Set<String> = []

    var menuBarIcon: String {
        currentMode.icon
    }

    func refreshVolume() {
        volume = deviceService.getOutputVolume()
        refreshDeviceVolumes()
    }

    /// Each section drives its own device's volume, so the levels of the active
    /// speaker, headphone and microphone are all tracked, not just the default.
    private func refreshDeviceVolumes() {
        var levels: [AudioObjectID: Float] = [:]
        if let outputId = currentOutputId {
            levels[outputId] = deviceService.getDeviceVolume(outputId, type: .output)
        }
        if let inputId = currentInputId {
            levels[inputId] = deviceService.getDeviceVolume(inputId, type: .input)
        }
        deviceVolumes = levels
    }

    func volume(for device: AudioDevice) -> Float {
        if let cached = deviceVolumes[device.id] { return cached }
        return deviceService.getDeviceVolume(device.id, type: device.type)
    }

    func setVolume(_ newVolume: Float, for device: AudioDevice) {
        let clamped = max(0, min(1, newVolume))
        deviceVolumes[device.id] = clamped
        deviceService.setDeviceVolume(device.id, type: device.type, volume: clamped)
        if device.id == currentOutputId {
            volume = clamped
        }
    }

    func hasVolumeControl(_ device: AudioDevice) -> Bool {
        device.isConnected && deviceService.deviceHasVolumeControl(device.id, type: device.type)
    }

    func toggleMute(_ device: AudioDevice) {
        guard device.isConnected else { return }
        let shouldMute = !isDeviceMuted(device)
        deviceService.setDeviceMuted(device.id, type: device.type, muted: shouldMute)
        refreshMuteStatus()
        refreshVolume()
    }

    func refreshMuteStatus() {
        var muted: Set<AudioObjectID> = []
        for device in inputDevices where device.isConnected {
            if deviceService.isDeviceMuted(device.id, type: .input) {
                muted.insert(device.id)
            }
        }
        for device in speakerDevices where device.isConnected {
            if deviceService.isDeviceMuted(device.id, type: .output) {
                muted.insert(device.id)
            }
        }
        for device in headphoneDevices where device.isConnected {
            if deviceService.isDeviceMuted(device.id, type: .output) {
                muted.insert(device.id)
            }
        }
        mutedDeviceIds = muted
        if let outputId = currentOutputId {
            isActiveOutputMuted = muted.contains(outputId)
        } else {
            isActiveOutputMuted = false
        }
        if let inputId = currentInputId {
            isActiveInputMuted = muted.contains(inputId)
        } else {
            isActiveInputMuted = false
        }
        if isActiveInputMuted && micFlashTimer == nil {
            micFlashTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.micFlashState.toggle()
                }
            }
        } else if !isActiveInputMuted && micFlashTimer != nil {
            micFlashTimer?.invalidate()
            micFlashTimer = nil
            micFlashState = false
        }
    }

    func isDeviceMuted(_ device: AudioDevice) -> Bool {
        mutedDeviceIds.contains(device.id)
    }

    func setVolume(_ newVolume: Float) {
        volume = newVolume
        deviceService.setOutputVolume(newVolume)
    }

    var activeOutputDevices: [AudioDevice] {
        switch currentMode {
        case .speaker: return speakerDevices
        case .headphone: return headphoneDevices
        }
    }

    init() {
        currentMode = priorityManager.currentMode
        refreshDevices()
        previousConnectedUIDs = connectedDeviceUIDs  // Initialize tracking
        refreshVolume()
        refreshMuteStatus()
        setupDeviceChangeListener()
        setupMuteVolumeListener()
        applyHighestPriorityInput()
        applyHighestPriorityOutput()
    }

    private func setupMuteVolumeListener() {
        deviceService.onMuteOrVolumeChanged = { [weak self] in
            Task { @MainActor in
                self?.handleMuteOrVolumeChange()
            }
        }
    }

    private func handleMuteOrVolumeChange() {
        refreshMuteStatus()
        refreshVolume()
    }

    func refreshDevices() {
        let allConnectedDevices = deviceService.getDevices()
        connectedDeviceUIDs = Set(allConnectedDevices.map { $0.uid })
        for device in allConnectedDevices {
            priorityManager.rememberDevice(device.uid, name: device.name, isInput: device.type == .input)
        }
        let connectedInputs = allConnectedDevices.filter { $0.type == .input }
        let connectedOutputs = allConnectedDevices.filter { $0.type == .output }

        if isEditMode {
            let knownDevices = priorityManager.getKnownDevices()
            var allInputs: [AudioDevice] = connectedInputs
            for stored in knownDevices where stored.isInput {
                if !connectedDeviceUIDs.contains(stored.uid) {
                    allInputs.append(.disconnected(uid: stored.uid, name: stored.name, type: .input))
                }
            }
            var allOutputs: [AudioDevice] = connectedOutputs
            for stored in knownDevices where !stored.isInput {
                if !connectedDeviceUIDs.contains(stored.uid) {
                    allOutputs.append(.disconnected(uid: stored.uid, name: stored.name, type: .output))
                }
            }
            inputDevices = priorityManager.sortByPriority(allInputs, type: .input)
            hiddenInputDevices = []
            let speakers = allOutputs.filter { priorityManager.getCategory(for: $0) == .speaker }
            let headphones = allOutputs.filter { priorityManager.getCategory(for: $0) == .headphone }
            speakerDevices = priorityManager.sortByPriority(speakers, category: .speaker)
            headphoneDevices = priorityManager.sortByPriority(headphones, category: .headphone)
            hiddenSpeakerDevices = []
            hiddenHeadphoneDevices = []
        } else {
            // Filter out hidden and never-use devices in normal mode
            let visibleInputs = connectedInputs.filter { !priorityManager.isHidden($0) && !priorityManager.isNeverUse($0) }
            // Hidden inputs: regular hidden first, then never-use
            let regularHiddenInputs = connectedInputs.filter { priorityManager.isHidden($0) && !priorityManager.isNeverUse($0) }
            let neverUseInputs = connectedInputs.filter { priorityManager.isNeverUse($0) }
            inputDevices = priorityManager.sortByPriority(visibleInputs, type: .input)
            hiddenInputDevices = regularHiddenInputs + neverUseInputs

            let speakers = connectedOutputs.filter { priorityManager.getCategory(for: $0) == .speaker }
            let headphones = connectedOutputs.filter { priorityManager.getCategory(for: $0) == .headphone }
            let visibleSpeakers = speakers.filter { !priorityManager.isHidden($0, inCategory: .speaker) && !priorityManager.isNeverUse($0) }
            let visibleHeadphones = headphones.filter { !priorityManager.isHidden($0, inCategory: .headphone) && !priorityManager.isNeverUse($0) }
            // Hidden outputs: regular hidden first, then never-use
            let regularHiddenSpeakers = speakers.filter { priorityManager.isHidden($0, inCategory: .speaker) && !priorityManager.isNeverUse($0) }
            let neverUseSpeakers = speakers.filter { priorityManager.isNeverUse($0) }
            let regularHiddenHeadphones = headphones.filter { priorityManager.isHidden($0, inCategory: .headphone) && !priorityManager.isNeverUse($0) }
            let neverUseHeadphones = headphones.filter { priorityManager.isNeverUse($0) }
            speakerDevices = priorityManager.sortByPriority(visibleSpeakers, category: .speaker)
            headphoneDevices = priorityManager.sortByPriority(visibleHeadphones, category: .headphone)
            hiddenSpeakerDevices = regularHiddenSpeakers + neverUseSpeakers
            hiddenHeadphoneDevices = regularHiddenHeadphones + neverUseHeadphones
        }
        currentInputId = deviceService.getCurrentDefaultDevice(type: .input)
        currentOutputId = deviceService.getCurrentDefaultDevice(type: .output)
    }

    func toggleEditMode() {
        isEditMode.toggle()
        refreshDevices()
    }

    func isDeviceConnected(_ device: AudioDevice) -> Bool {
        connectedDeviceUIDs.contains(device.uid)
    }

    /// Tracks device UIDs from the previous refresh to detect new connections
    private var previousConnectedUIDs: Set<String> = []
    
    /// Which output category auto-switching is currently aiming at. Set by the
    /// user picking a device, or by headphones appearing and disappearing.
    func setMode(_ mode: OutputCategory) {
        currentMode = mode
        priorityManager.currentMode = mode
    }

    func setCategory(_ category: OutputCategory, for device: AudioDevice) {
        priorityManager.setCategory(category, for: device)
        refreshDevices()
        applyHighestPriorityOutput()
    }

    func hideDevice(_ device: AudioDevice, category: OutputCategory? = nil) {
        if device.type == .input {
            priorityManager.hideDevice(device)
        } else if let cat = category {
            priorityManager.hideDevice(device, inCategory: cat)
        } else {
            priorityManager.hideDevice(device)
        }
        refreshDevices()
        if device.type == .input {
            applyHighestPriorityInput()
        } else {
            applyHighestPriorityOutput()
        }
    }

    /// Ignores the device in every list it can appear in. Devices with both
    /// inputs and outputs - aggregates, interfaces - show up twice, and
    /// "entirely" has to mean both.
    func hideDeviceEntirely(_ device: AudioDevice) {
        priorityManager.hideDeviceEverywhere(device)
        refreshDevices()
        applyHighestPriorityInput()
        applyHighestPriorityOutput()
    }

    func unhideDevice(_ device: AudioDevice, category: OutputCategory? = nil) {
        // Unhiding from the ignored list undoes an "ignore entirely" too.
        priorityManager.unhideDeviceEverywhere(device)
        if device.type == .input {
            priorityManager.unhideDevice(device)
        } else if let cat = category {
            priorityManager.unhideDevice(device, fromCategory: cat)
        } else {
            priorityManager.unhideDevice(device)
        }
        refreshDevices()
    }

    func isDeviceIgnored(_ device: AudioDevice, inCategory category: OutputCategory? = nil) -> Bool {
        if device.type == .input {
            return priorityManager.isHidden(device)
        } else if let cat = category {
            return priorityManager.isHidden(device, inCategory: cat)
        } else {
            return priorityManager.isHidden(device)
        }
    }

    func isNeverUse(_ device: AudioDevice) -> Bool {
        priorityManager.isNeverUse(device)
    }

    func setNeverUse(_ device: AudioDevice, neverUse: Bool) {
        priorityManager.setNeverUse(device, neverUse: neverUse)
        refreshDevices()
        if device.type == .input {
            applyHighestPriorityInput()
        } else {
            applyHighestPriorityOutput()
        }
    }

    func moveInputDevice(from source: IndexSet, to destination: Int) {
        inputDevices.move(fromOffsets: source, toOffset: destination)
        priorityManager.savePriorities(inputDevices, type: .input)
        // Switch to top input if it's connected
        if let topInput = inputDevices.first, topInput.isConnected {
            applyInputDevice(topInput)
        }
    }

    func moveSpeakerDevice(from source: IndexSet, to destination: Int) {
        speakerDevices.move(fromOffsets: source, toOffset: destination)
        priorityManager.savePriorities(speakerDevices, category: .speaker)
        // Switch to top speaker only if we're in speaker mode and top speaker is connected
        if currentMode == .speaker, let topSpeaker = speakerDevices.first, topSpeaker.isConnected {
            applyOutputDevice(topSpeaker)
        }
    }

    func moveHeadphoneDevice(from source: IndexSet, to destination: Int) {
        headphoneDevices.move(fromOffsets: source, toOffset: destination)
        priorityManager.savePriorities(headphoneDevices, category: .headphone)
        // Switch to top headphone if it's connected
        if let topHeadphone = headphoneDevices.first, topHeadphone.isConnected {
            applyOutputDevice(topHeadphone)
        }
    }

    func setInputDevice(_ device: AudioDevice) {
        applyInputDevice(device)
    }

    func setOutputDevice(_ device: AudioDevice) {
        applyOutputDevice(device)
    }

    private func applyInputDevice(_ device: AudioDevice) {
        deviceService.setDefaultDevice(device.id, type: .input)
        currentInputId = device.id
    }

    private func applyOutputDevice(_ device: AudioDevice) {
        deviceService.setDefaultDevice(device.id, type: .output)
        currentOutputId = device.id
    }

    private func applyHighestPriorityInput() {
        if let first = inputDevices.first(where: { $0.isConnected && !priorityManager.isNeverUse($0) }) {
            applyInputDevice(first)
        }
    }

    private func applyHighestPriorityOutput() {
        let devices = activeOutputDevices
        if let first = devices.first(where: { $0.isConnected && !priorityManager.isNeverUse($0) }) {
            applyOutputDevice(first)
        }
        refreshMuteStatus()
    }

    private func setupDeviceChangeListener() {
        deviceService.onDevicesChanged = { [weak self] in
            Task { @MainActor in
                self?.handleDeviceChange()
            }
        }
        deviceService.startListening()
    }

    private func handleDeviceChange() {
        let oldConnectedUIDs = previousConnectedUIDs
        refreshDevices()
        refreshMuteStatus()
        
        // Detect newly connected devices
        let newlyConnectedUIDs = connectedDeviceUIDs.subtracting(oldConnectedUIDs)
        previousConnectedUIDs = connectedDeviceUIDs
        
        // Auto-switch mode only when a new headphone connects or all headphones disconnect
        autoSwitchModeIfNeeded(newlyConnectedUIDs: newlyConnectedUIDs)
        applyHighestPriorityInput()
        applyHighestPriorityOutput()
    }
    
    /// Automatically switches between headphone and speaker mode based on device connections.
    /// Only triggers on:
    /// 1. A new headphone device connects → switch to headphone mode
    /// 2. All headphones disconnect → switch to speaker mode
    private func autoSwitchModeIfNeeded(newlyConnectedUIDs: Set<String>) {
        let connectedHeadphones = headphoneDevices.filter { $0.isConnected }
        let hasConnectedHeadphones = !connectedHeadphones.isEmpty
        let hasConnectedSpeakers = speakerDevices.contains { $0.isConnected }
        
        // Check if a new headphone just connected
        let newHeadphoneConnected = connectedHeadphones.contains { newlyConnectedUIDs.contains($0.uid) }
        
        if newHeadphoneConnected && currentMode != .headphone {
            // A new headphone just connected - switch to headphone mode
            currentMode = .headphone
            priorityManager.currentMode = .headphone
        } else if !hasConnectedHeadphones && hasConnectedSpeakers && currentMode == .headphone {
            // All headphones disconnected - switch back to speaker mode
            currentMode = .speaker
            priorityManager.currentMode = .speaker
        }
    }
}
