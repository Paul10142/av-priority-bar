import AppKit
import Carbon.HIToolbox

/// A single system-wide keyboard shortcut, registered through Carbon's
/// RegisterEventHotKey. That API needs no accessibility permission, unlike an
/// event tap, which matters for an app that shouldn't be asking for more access
/// than it needs.
@MainActor
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()

    @Published private(set) var keyCode: UInt32?
    @Published private(set) var modifiers: UInt32?
    /// Set while the settings page is waiting for the user to press a combo.
    @Published var isRecording = false

    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var recordingMonitor: Any?
    private let defaults = UserDefaults.standard

    private init() {
        if let stored = defaults.object(forKey: "hotKeyCode") as? Int,
           let mods = defaults.object(forKey: "hotKeyModifiers") as? Int {
            keyCode = UInt32(stored)
            modifiers = UInt32(mods)
        }
    }

    var displayString: String {
        guard let keyCode, let modifiers else { return "None" }
        return Self.describe(keyCode: keyCode, carbonModifiers: modifiers)
    }

    // MARK: - Registration

    func registerStoredHotKey() {
        guard let keyCode, let modifiers else { return }
        register(keyCode: keyCode, modifiers: modifiers)
    }

    func clear() {
        unregister()
        keyCode = nil
        modifiers = nil
        defaults.removeObject(forKey: "hotKeyCode")
        defaults.removeObject(forKey: "hotKeyModifiers")
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x41565042), id: 1) // 'AVPB'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
        }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                HotKeyManager.shared.onTrigger?()
            }
            return noErr
        }, 1, &eventType, nil, &eventHandler)
    }

    // MARK: - Recording

    func startRecording() {
        guard recordingMonitor == nil else { return }
        isRecording = true
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.stopRecording()
                return nil
            }
            let carbonMods = Self.carbonModifiers(from: event.modifierFlags)
            // A bare key would fire while typing anywhere, so require a modifier.
            guard carbonMods != 0 else { return nil }

            let code = UInt32(event.keyCode)
            self.keyCode = code
            self.modifiers = carbonMods
            self.defaults.set(Int(code), forKey: "hotKeyCode")
            self.defaults.set(Int(carbonMods), forKey: "hotKeyModifiers")
            self.register(keyCode: code, modifiers: carbonMods)
            self.stopRecording()
            return nil
        }
    }

    func stopRecording() {
        if let recordingMonitor {
            NSEvent.removeMonitor(recordingMonitor)
            self.recordingMonitor = nil
        }
        isRecording = false
    }

    // MARK: - Formatting

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }

    private static func describe(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        var parts = ""
        if carbonModifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        return parts + keyName(for: keyCode)
    }

    private static func keyName(for keyCode: UInt32) -> String {
        let named: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab",
            kVK_Escape: "Esc", kVK_Delete: "Delete",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9"
        ]
        return named[Int(keyCode)] ?? "Key \(keyCode)"
    }
}
