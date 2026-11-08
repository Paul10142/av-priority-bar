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
    // MARK: - Known cameras

    func getKnownCameras() -> [StoredCamera] {
        guard let data = defaults.data(forKey: knownCamerasKey),
              let cameras = try? JSONDecoder().decode([StoredCamera].self, from: data) else {
            return []
        }
        return cameras
    }

    /// Returns true the first time this uniqueID is seen.
    @discardableResult
    func rememberCamera(_ camera: CameraDevice) -> Bool {
        var known = getKnownCameras()
        let entry = StoredCamera(uniqueID: camera.uniqueID, name: camera.name, kind: camera.kind, lastSeen: Date())
        let isNew: Bool
        if let index = known.firstIndex(where: { $0.uniqueID == camera.uniqueID }) {
            known[index] = entry
            isNew = false
        } else {
            known.append(entry)
            isNew = true
        }
        saveKnownCameras(known)
        return isNew
    }

    /// A USB camera's uniqueID changes with the port or hub it is plugged into -
    /// the same Facecam has been seen under two. Each ID was remembered as a
    /// camera of its own, which meant duplicate rows and a rank that stayed
    /// with whichever ID it had last been dragged under. Cameras with the same
    /// name and kind are treated as one: the one connected now (or, if none,
    /// the one seen last) keeps the entry and inherits the best rank any of
    /// them held; the others are dropped.
    func consolidateDuplicates(connectedIDs: Set<String>) {
        var known = getKnownCameras()
        var order = getPriorityOrder()
        var ignored = defaults.array(forKey: ignoredCamerasKey) as? [String] ?? []
        let original = (known, order, ignored)

        let groups = Dictionary(grouping: known) { "\($0.kind.rawValue)|\($0.name)" }
        for group in groups.values where group.count > 1 {
            let connected = group.filter { connectedIDs.contains($0.uniqueID) }
            let keepers = connected.isEmpty ? [group.max { $0.lastSeen < $1.lastSeen }!] : connected
            let keeperIDs = Set(keepers.map { $0.uniqueID })
            let dropped = group.map { $0.uniqueID }.filter { !keeperIDs.contains($0) }
            guard !dropped.isEmpty, let keeper = keepers.first?.uniqueID else { continue }

            if !order.contains(keeper), let slot = dropped.compactMap({ order.firstIndex(of: $0) }).min() {
                order[slot] = keeper
            }
            if !ignored.contains(keeper), dropped.contains(where: { ignored.contains($0) }) {
                ignored.append(keeper)
            }
            known.removeAll { dropped.contains($0.uniqueID) }
            order.removeAll { dropped.contains($0) }
            ignored.removeAll { dropped.contains($0) }
        }

        if known != original.0 { saveKnownCameras(known) }
        if order != original.1 { defaults.set(order, forKey: prioritiesKey) }
        if ignored != original.2 { defaults.set(ignored, forKey: ignoredCamerasKey) }
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
        let known = getKnownCameras()
        func rank(_ camera: CameraDevice) -> Int {
            if let index = order.firstIndex(of: camera.uniqueID) { return index }
            // A USB camera's uniqueID changes with the port or hub it is
            // plugged into - the same Facecam has been seen under two. Borrow
            // the rank of a remembered camera with the same name, so moving a
            // cable doesn't send it to the bottom of the list.
            return known
                .filter { $0.name == camera.name && $0.uniqueID != camera.uniqueID }
                .compactMap { order.firstIndex(of: $0.uniqueID) }
                .min() ?? Int.max
        }
        return cameras.enumerated().sorted { a, b in
            let rankA = rank(a.element)
            let rankB = rank(b.element)
            // Stable: fall back to the original discovery order on ties.
            return rankA == rankB ? a.offset < b.offset : rankA < rankB
        }.map { $0.element }
    }

    func savePriorities(_ cameras: [CameraDevice]) {
        // Cameras that aren't in this list (ignored ones) keep their slots; the
        // visible ones fill the rest in their new order.
        let merged = PriorityOrder.merged(visible: cameras.map { $0.uniqueID }, into: getPriorityOrder())
        defaults.set(merged, forKey: prioritiesKey)
    }

    /// A camera seen for the first time has no rank and would sort below every
    /// ranked one - under the built-in camera, so a newly bought webcam was
    /// never used. External hardware goes just above the built-in camera
    /// instead. Left alone on a first run, when the starting order is seeded
    /// from scratch.
    func placeNew(_ camera: CameraDevice, aboveBuiltIn builtInIDs: Set<String>) {
        var order = getPriorityOrder()
        guard !order.isEmpty, !order.contains(camera.uniqueID) else { return }
        order.insert(camera.uniqueID, at: order.firstIndex { builtInIDs.contains($0) } ?? 0)
        defaults.set(order, forKey: prioritiesKey)
    }

    /// Moves a camera to the top of the priority list.
    func promoteToTop(_ camera: CameraDevice) {
        var order = getPriorityOrder()
        order.removeAll { $0 == camera.uniqueID }
        order.insert(camera.uniqueID, at: 0)
        defaults.set(order, forKey: prioritiesKey)
    }
}
