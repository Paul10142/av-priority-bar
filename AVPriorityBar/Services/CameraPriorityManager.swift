import Foundation

struct StoredCamera: Codable, Equatable {
    let uniqueID: String
    let name: String
    let kind: CameraKind
    var lastSeen: Date

    var lastSeenRelative: String {
        let interval = Date().timeIntervalSince(lastSeen)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        if interval < 604800 { return "\(Int(interval / 86400))d ago" }
        if interval < 2592000 { return "\(Int(interval / 604800))w ago" }
        return "\(Int(interval / 2592000))mo ago"
    }
}

/// Persistence for the camera priority list. Mirrors `PriorityManager`, keyed by
/// `AVCaptureDevice.uniqueID` so a camera keeps its rank across reconnects.
final class CameraPriorityManager {
    private let defaults = UserDefaults.standard

    private let prioritiesKey = "cameraPriorities"
    private let knownCamerasKey = "knownCameras"
    private let ignoredCamerasKey = "ignoredCameras"
    private let autoSwitchKey = "cameraAutoSwitch"

    // MARK: - Auto-switching

    /// When on, the highest-priority connected camera is made the system
    /// preference automatically. Defaults to on for a first run.
    var isAutoSwitchEnabled: Bool {
        get {
            if defaults.object(forKey: autoSwitchKey) == nil { return true }
            return defaults.bool(forKey: autoSwitchKey)
        }
        set { defaults.set(newValue, forKey: autoSwitchKey) }
    }

    // MARK: - Known cameras

    func getKnownCameras() -> [StoredCamera] {
        guard let data = defaults.data(forKey: knownCamerasKey),
              let cameras = try? JSONDecoder().decode([StoredCamera].self, from: data) else {
            return []
        }
        return cameras
    }

    func rememberCamera(_ camera: CameraDevice) {
        var known = getKnownCameras()
        let entry = StoredCamera(uniqueID: camera.uniqueID, name: camera.name, kind: camera.kind, lastSeen: Date())
        if let index = known.firstIndex(where: { $0.uniqueID == camera.uniqueID }) {
            known[index] = entry
        } else {
            known.append(entry)
        }
        saveKnownCameras(known)
    }

    func getStoredCamera(uniqueID: String) -> StoredCamera? {
        getKnownCameras().first { $0.uniqueID == uniqueID }
    }

    func forgetCamera(_ uniqueID: String) {
        var known = getKnownCameras()
        known.removeAll { $0.uniqueID == uniqueID }
        saveKnownCameras(known)
        var order = getPriorityOrder()
        order.removeAll { $0 == uniqueID }
        defaults.set(order, forKey: prioritiesKey)
    }

    private func saveKnownCameras(_ cameras: [StoredCamera]) {
        if let data = try? JSONEncoder().encode(cameras) {
            defaults.set(data, forKey: knownCamerasKey)
        }
    }

    // MARK: - Ignored cameras (never auto-selected)

    func isIgnored(_ camera: CameraDevice) -> Bool {
        (defaults.array(forKey: ignoredCamerasKey) as? [String] ?? []).contains(camera.uniqueID)
    }

    func setIgnored(_ camera: CameraDevice, ignored: Bool) {
        var list = defaults.array(forKey: ignoredCamerasKey) as? [String] ?? []
        if ignored {
            if !list.contains(camera.uniqueID) { list.append(camera.uniqueID) }
        } else {
            list.removeAll { $0 == camera.uniqueID }
        }
        defaults.set(list, forKey: ignoredCamerasKey)
    }

    // MARK: - Priority order

    func getPriorityOrder() -> [String] {
        defaults.array(forKey: prioritiesKey) as? [String] ?? []
    }

    func sortByPriority(_ cameras: [CameraDevice]) -> [CameraDevice] {
        let order = getPriorityOrder()
        return cameras.enumerated().sorted { a, b in
            let rankA = order.firstIndex(of: a.element.uniqueID) ?? Int.max
            let rankB = order.firstIndex(of: b.element.uniqueID) ?? Int.max
            // Stable: fall back to the original discovery order on ties.
            return rankA == rankB ? a.offset < b.offset : rankA < rankB
        }.map { $0.element }
    }

    func savePriorities(_ cameras: [CameraDevice]) {
        // Preserve the rank of cameras that aren't in this list (disconnected and
        // hidden from the current view) instead of dropping them from the order.
        let visible = cameras.map { $0.uniqueID }
        let retained = getPriorityOrder().filter { !visible.contains($0) }
        defaults.set(visible + retained, forKey: prioritiesKey)
    }

    /// Moves a camera to the top of the priority list.
    func promoteToTop(_ camera: CameraDevice) {
        var order = getPriorityOrder()
        order.removeAll { $0 == camera.uniqueID }
        order.insert(camera.uniqueID, at: 0)
        defaults.set(order, forKey: prioritiesKey)
    }
}
