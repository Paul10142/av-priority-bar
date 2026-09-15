import Foundation

/// One-time import of settings from the original Audio Priority Bar
/// (`com.example.AudioPriorityBar`), so a first launch of this build starts with
/// the same device order rather than a blank slate. Audio keys only - the camera
/// side has no history to inherit.
enum SettingsMigration {
    private static let migratedKey = "migratedFromAudioPriorityBar"
    private static let sourceDomain = "com.example.AudioPriorityBar"

    private static let keys = [
        "inputPriorities",
        "speakerPriorities",
        "headphonePriorities",
        "deviceCategories",
        "currentMode",
        "customMode",
        "hiddenDevices",
        "knownDevices",
        "neverUseDevices",
        "hiddenMics",
        "hiddenSpeakers",
        "hiddenHeadphones"
    ]

    @discardableResult
    static func runIfNeeded() -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return false }
        defaults.set(true, forKey: migratedKey)

        guard let source = UserDefaults(suiteName: sourceDomain) else { return false }
        var copied = 0
        for key in keys {
            // Never overwrite a value this build has already written.
            guard defaults.object(forKey: key) == nil,
                  let value = source.object(forKey: key) else { continue }
            defaults.set(value, forKey: key)
            copied += 1
        }
        return copied > 0
    }
}
