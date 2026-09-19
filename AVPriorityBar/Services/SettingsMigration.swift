import Foundation

/// One-time import of settings from a previous identity of this app, so a first
/// launch starts with the same device order rather than a blank slate.
///
/// There have been two: `com.example.AudioPriorityBar`, the upstream project
/// this was forked from, and `com.paulclancy.AVPriorityBar`, which macOS's menu
/// bar now refuses to place an icon for (see build.sh). Domains are read
/// newest-first, so a key present in both takes the more recent value.
enum SettingsMigration {
    private static let migratedKey = "migratedFromPreviousIdentity"

    private static let sourceDomains = [
        "com.paulclancy.AVPriorityBar",
        "com.example.AudioPriorityBar",
    ]

    /// Audio and camera keys the upstream app also had. Anything outside this
    /// list is only inherited from our own previous identity, below.
    private static let sharedKeys = [
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

    /// Menu bar placement is deliberately not inherited: those keys record the
    /// slot macOS gave the icon under the old identifier, which is the state a
    /// new identifier exists to leave behind. Window frames are dropped for the
    /// same reason -- they are tied to a screen layout, not to a preference.
    private static func isExcluded(_ key: String) -> Bool {
        key.hasPrefix("NSStatusItem ") || key.hasPrefix("NSWindow Frame ")
    }

    @discardableResult
    static func runIfNeeded() -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return false }
        defaults.set(true, forKey: migratedKey)

        var copied = 0
        for domain in sourceDomains {
            guard let source = defaults.persistentDomain(forName: domain) else { continue }
            // Our own previous identity carries everything; the upstream fork
            // only ever had the shared audio keys, and the rest of its domain is
            // not ours to interpret.
            let isOurs = domain.hasPrefix("com.paulclancy.")
            for (key, value) in source {
                guard isOurs || sharedKeys.contains(key) else { continue }
                guard !isExcluded(key) else { continue }
                // Never overwrite a value this build has already written.
                guard defaults.object(forKey: key) == nil else { continue }
                defaults.set(value, forKey: key)
                copied += 1
            }
        }

        // Keep the old flag in step, so a build from before this change running
        // against the same domain does not migrate a second time.
        defaults.set(true, forKey: "migratedFromAudioPriorityBar")
        return copied > 0
    }
}
