import Foundation

struct StoredDevice: Codable, Equatable {
    let uid: String
    let name: String
    let isInput: Bool
    var lastSeen: Date

    var lastSeenRelative: String {
        let now = Date()
        let interval = now.timeIntervalSince(lastSeen)

        if interval < 60 {
            return "now"
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else if interval < 604800 {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        } else if interval < 2592000 {
            let weeks = Int(interval / 604800)
            return "\(weeks)w ago"
        } else {
            let months = Int(interval / 2592000)
            return "\(months)mo ago"
        }
    }
}

class PriorityManager {
    private let defaults = UserDefaults.standard

    private let inputPrioritiesKey = "inputPriorities"
    private let speakerPrioritiesKey = "speakerPriorities"
    private let headphonePrioritiesKey = "headphonePriorities"
    private let deviceCategoriesKey = "deviceCategories"
    private let currentModeKey = "currentMode"
    private let hiddenDevicesKey = "hiddenDevices"
    private let knownDevicesKey = "knownDevices"

    // MARK: - Known Devices (Persistent Memory)

    func getKnownDevices() -> [StoredDevice] {
        guard let data = defaults.data(forKey: knownDevicesKey),
              let devices = try? JSONDecoder().decode([StoredDevice].self, from: data) else {
            return []
        }
        return devices
    }

    func rememberDevice(_ uid: String, name: String, isInput: Bool) {
        guard !AudioDeviceService.isTransient(uid: uid, name: name) else { return }
        var known = getKnownDevices()
        let now = Date()
        if let index = known.firstIndex(where: { $0.uid == uid }) {
            // Update name and lastSeen
            known[index] = StoredDevice(uid: uid, name: name, isInput: isInput, lastSeen: now)
        } else {
            known.append(StoredDevice(uid: uid, name: name, isInput: isInput, lastSeen: now))
        }
        saveKnownDevices(known)
    }

    func getStoredDevice(uid: String) -> StoredDevice? {
        getKnownDevices().first { $0.uid == uid }
    }

    func forgetDevice(_ uid: String) {
        var known = getKnownDevices()
        known.removeAll { $0.uid == uid }
        saveKnownDevices(known)
    }

    private func saveKnownDevices(_ devices: [StoredDevice]) {
        if let data = try? JSONEncoder().encode(devices) {
            defaults.set(data, forKey: knownDevicesKey)
        }
    }

    /// Drops macOS's throwaway aggregate devices from every stored list.
    /// Before the device list learned to leave them out, each appearance was
    /// remembered under its own one-off name - 231 of them on one machine -
    /// and ignored one at a time; nothing can ever match those entries again.
    func pruneTransientDevices() {
        let known = getKnownDevices()
        let keptKnown = known.filter { !AudioDeviceService.isTransient(uid: $0.uid, name: $0.name) }
        if keptKnown.count != known.count {
            saveKnownDevices(keptKnown)
        }

        var listKeys = [inputPrioritiesKey, speakerPrioritiesKey, headphonePrioritiesKey, neverUseKey]
        for key in [hiddenMicsKey, hiddenSpeakersKey, hiddenHeadphonesKey, neverUseKey] {
            listKeys.append(key)
            listKeys.append(namesKey(key))
        }
        for key in listKeys {
            guard let list = defaults.array(forKey: key) as? [String] else { continue }
            let kept = list.filter { !AudioDeviceService.isTransient(uid: $0, name: $0) }
            if kept.count != list.count {
                defaults.set(kept, forKey: key)
            }
        }
    }

    // MARK: - Mode Management

    var currentMode: OutputCategory {
        get {
            guard let raw = defaults.string(forKey: currentModeKey),
                  let mode = OutputCategory(rawValue: raw) else {
                return .speaker
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: currentModeKey)
        }
    }

    // MARK: - Device Categories

    func getCategory(for device: AudioDevice) -> OutputCategory {
        let categories = defaults.dictionary(forKey: deviceCategoriesKey) as? [String: String] ?? [:]
        if let raw = categories[device.uid], let category = OutputCategory(rawValue: raw) {
            return category
        }
        // Default headphone-like devices to headphone category
        if HeadphoneDetection.isHeadphone(deviceName: device.name) {
            return .headphone
        }
        return .speaker
    }

    func setCategory(_ category: OutputCategory, for device: AudioDevice) {
        var categories = defaults.dictionary(forKey: deviceCategoriesKey) as? [String: String] ?? [:]
        categories[device.uid] = category.rawValue
        defaults.set(categories, forKey: deviceCategoriesKey)
    }

    // MARK: - Never Use Devices (never auto-selected)

    private let neverUseKey = "neverUseDevices"

    func isNeverUse(_ device: AudioDevice) -> Bool {
        let list = defaults.array(forKey: neverUseKey) as? [String] ?? []
        if list.contains(device.uid) { return true }
        let names = defaults.array(forKey: neverUseKey + "Names") as? [String] ?? []
        return names.contains(device.name)
    }

    func setNeverUse(_ device: AudioDevice, neverUse: Bool) {
        var list = defaults.array(forKey: neverUseKey) as? [String] ?? []
        var names = defaults.array(forKey: neverUseKey + "Names") as? [String] ?? []
        if neverUse {
            if !list.contains(device.uid) { list.append(device.uid) }
            if !names.contains(device.name) { names.append(device.name) }
        } else {
            list.removeAll { $0 == device.uid }
            names.removeAll { $0 == device.name }
        }
        defaults.set(list, forKey: neverUseKey)
        defaults.set(names, forKey: neverUseKey + "Names")
    }

    // MARK: - Hidden Devices (per category)

    private let hiddenMicsKey = "hiddenMics"
    private let hiddenSpeakersKey = "hiddenSpeakers"
    private let hiddenHeadphonesKey = "hiddenHeadphones"

    func isHidden(_ device: AudioDevice) -> Bool {
        isHidden(device, key: hiddenKey(for: device))
    }

    func isHidden(_ device: AudioDevice, inCategory category: OutputCategory) -> Bool {
        isHidden(device, key: category == .speaker ? hiddenSpeakersKey : hiddenHeadphonesKey)
    }

    func hideDevice(_ device: AudioDevice) {
        hide(device, key: hiddenKey(for: device))
    }

    func hideDevice(_ device: AudioDevice, inCategory category: OutputCategory) {
        hide(device, key: category == .speaker ? hiddenSpeakersKey : hiddenHeadphonesKey)
    }

    func unhideDevice(_ device: AudioDevice) {
        unhide(device, key: hiddenKey(for: device))
    }

    func unhideDevice(_ device: AudioDevice, fromCategory category: OutputCategory) {
        unhide(device, key: category == .speaker ? hiddenSpeakersKey : hiddenHeadphonesKey)
    }

    /// Hides every list a device can appear in - microphones included, which is
    /// what "ignore entirely" is asked to do for devices that are both.
    func hideDeviceEverywhere(_ device: AudioDevice) {
        hide(device, key: hiddenSpeakersKey)
        hide(device, key: hiddenHeadphonesKey)
        hide(device, key: hiddenMicsKey)
    }

    func unhideDeviceEverywhere(_ device: AudioDevice) {
        unhide(device, key: hiddenSpeakersKey)
        unhide(device, key: hiddenHeadphonesKey)
        unhide(device, key: hiddenMicsKey)
    }

    // Some devices - macOS's own CADefaultDeviceAggregate in particular - get a
    // fresh UID every time they appear, so a UID-keyed ignore silently forgets
    // them on the next launch. Names are recorded alongside and matched too.
    private func namesKey(_ key: String) -> String { key + "Names" }

    private func isHidden(_ device: AudioDevice, key: String) -> Bool {
        let uids = defaults.array(forKey: key) as? [String] ?? []
        if uids.contains(device.uid) { return true }
        let names = defaults.array(forKey: namesKey(key)) as? [String] ?? []
        return names.contains(device.name)
    }

    private func hide(_ device: AudioDevice, key: String) {
        var uids = defaults.array(forKey: key) as? [String] ?? []
        if !uids.contains(device.uid) {
            uids.append(device.uid)
            defaults.set(uids, forKey: key)
        }
        var names = defaults.array(forKey: namesKey(key)) as? [String] ?? []
        if !names.contains(device.name) {
            names.append(device.name)
            defaults.set(names, forKey: namesKey(key))
        }
    }

    private func unhide(_ device: AudioDevice, key: String) {
        var uids = defaults.array(forKey: key) as? [String] ?? []
        uids.removeAll { $0 == device.uid }
        defaults.set(uids, forKey: key)

        var names = defaults.array(forKey: namesKey(key)) as? [String] ?? []
        names.removeAll { $0 == device.name }
        defaults.set(names, forKey: namesKey(key))
    }

    private func hiddenKey(for device: AudioDevice) -> String {
        if device.type == .input {
            return hiddenMicsKey
        } else {
            let category = getCategory(for: device)
            return category == .speaker ? hiddenSpeakersKey : hiddenHeadphonesKey
        }
    }

    // MARK: - Priority Management

    func sortByPriority(_ devices: [AudioDevice], type: AudioDeviceType) -> [AudioDevice] {
        let key = priorityKey(for: type, category: nil)
        return sortDevices(devices, usingKey: key)
    }

    func sortByPriority(_ devices: [AudioDevice], category: OutputCategory) -> [AudioDevice] {
        let key = priorityKey(for: .output, category: category)
        return sortDevices(devices, usingKey: key)
    }

    func savePriorities(_ devices: [AudioDevice], type: AudioDeviceType) {
        let key = priorityKey(for: type, category: nil)
        savePriorities(devices, key: key)
    }

    func savePriorities(_ devices: [AudioDevice], category: OutputCategory) {
        let key = priorityKey(for: .output, category: category)
        savePriorities(devices, key: key)
    }

    // MARK: - Private Helpers

    private func priorityKey(for type: AudioDeviceType, category: OutputCategory?) -> String {
        switch type {
        case .input:
            return inputPrioritiesKey
        case .output:
            switch category {
            case .speaker, .none:
                return speakerPrioritiesKey
            case .headphone:
                return headphonePrioritiesKey
            }
        }
    }

    private func sortDevices(_ devices: [AudioDevice], usingKey key: String) -> [AudioDevice] {
        let priorities = defaults.array(forKey: key) as? [String] ?? []

        return devices.sorted { a, b in
            let indexA = priorities.firstIndex(of: a.uid) ?? Int.max
            let indexB = priorities.firstIndex(of: b.uid) ?? Int.max
            return indexA < indexB
        }
    }

    private func savePriorities(_ devices: [AudioDevice], key: String) {
        let uids = devices.map { $0.uid }
        defaults.set(uids, forKey: key)
    }
}
