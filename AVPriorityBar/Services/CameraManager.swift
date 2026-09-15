import Foundation
import AVFoundation
import SwiftUI

/// Camera-side counterpart to `AudioManager`: keeps the priority list, reacts to
/// cameras connecting and disconnecting, and applies the system-wide preference.
@MainActor
final class CameraManager: ObservableObject {
    /// Shared so the hotkey and the floating window can reach the same state
    /// the panel is showing.
    static let shared = CameraManager()

    @Published var cameras: [CameraDevice] = []
    @Published var ignoredCameras: [CameraDevice] = []
    @Published var currentPreferredID: String?
    @Published var authState: CameraAuthState = .notDetermined
    /// Which camera the preview is showing because the pointer is over its row.
    /// Hovering is look-only - it never changes priority or the active camera.
    @Published var hoveredCameraID: String?
    /// The camera you last clicked. The preview follows this, because macOS
    /// won't accept every camera as the system preference (Desk View, for one)
    /// and the preview should still show what you asked for.
    @Published var selectedCameraID: String?
    @Published var isEditMode: Bool = false

    private let service = CameraService()
    let priorityManager = CameraPriorityManager()
    private var connectedIDs: Set<String> = []

    init() {
        authState = service.authState
        refreshCameras()
        seedDefaultOrderIfNeeded()
        setupListeners()
        applyHighestPriorityCamera()
    }

    /// On a first run there is no saved order, so the raw discovery order would
    /// decide which camera the whole system gets - and that order can easily put
    /// a virtual camera first. Seed something sensible instead: whatever macOS is
    /// already using stays on top, then real hardware, then software cameras.
    private func seedDefaultOrderIfNeeded() {
        guard priorityManager.getPriorityOrder().isEmpty, !cameras.isEmpty else { return }
        let current = service.currentPreferredUniqueID
        let seeded = cameras.sorted { a, b in
            if a.uniqueID == current { return true }
            if b.uniqueID == current { return false }
            if a.kind.defaultRank != b.kind.defaultRank {
                return a.kind.defaultRank < b.kind.defaultRank
            }
            return a.name < b.name
        }
        priorityManager.savePriorities(seeded)
        refreshCameras()
    }

    // MARK: - Permission

    /// Camera names are only readable once access is granted, so the list stays
    /// empty until the user approves the prompt.
    func requestAccessIfNeeded() {
        guard authState == .notDetermined else { return }
        service.requestAccess { [weak self] _ in
            guard let self else { return }
            self.authState = self.service.authState
            self.refreshCameras()
            self.applyHighestPriorityCamera()
        }
    }

    func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Refresh

    func refreshCameras() {
        authState = service.authState
        let connected = service.getDevices()
        connectedIDs = Set(connected.map { $0.uniqueID })
        for camera in connected {
            priorityManager.rememberCamera(camera)
        }

        var all = connected
        if isEditMode {
            // Edit mode also shows every camera ever seen, so old ones can be
            // ranked or forgotten while unplugged.
            for stored in priorityManager.getKnownCameras() where !connectedIDs.contains(stored.uniqueID) {
                all.append(.disconnected(uniqueID: stored.uniqueID, name: stored.name, kind: stored.kind))
            }
        }

        let sorted = priorityManager.sortByPriority(all)
        if isEditMode {
            cameras = sorted
            ignoredCameras = []
        } else {
            cameras = sorted.filter { !priorityManager.isIgnored($0) }
            ignoredCameras = sorted.filter { priorityManager.isIgnored($0) }
        }
        currentPreferredID = service.currentPreferredUniqueID
    }

    func isConnected(_ camera: CameraDevice) -> Bool {
        connectedIDs.contains(camera.uniqueID)
    }

    func lastSeen(_ camera: CameraDevice) -> String? {
        guard !isConnected(camera) else { return nil }
        return priorityManager.getStoredCamera(uniqueID: camera.uniqueID)?.lastSeenRelative
    }

    var topPriorityCamera: CameraDevice? {
        cameras.first { isConnected($0) && !priorityManager.isIgnored($0) }
    }

    /// True when the active camera is not the one priority says it should be -
    /// either you picked another one, or another app wrote its own preference.
    var isOverridden: Bool {
        guard let top = topPriorityCamera, let current = currentPreferredID else { return false }
        return top.uniqueID != current
    }

    // MARK: - Actions

    /// A click uses the camera now. It never reorders the list - that is what
    /// dragging is for.
    func selectCamera(_ camera: CameraDevice) {
        guard isConnected(camera) else { return }
        selectedCameraID = camera.uniqueID
        service.setPreferred(uniqueID: camera.uniqueID)
        refreshCameras()
        MirrorWindowController.shared.showCamera(uniqueID: camera.uniqueID, name: camera.name)
    }

    func moveCamera(from source: IndexSet, to destination: Int) {
        cameras.move(fromOffsets: source, toOffset: destination)
        priorityManager.savePriorities(cameras)
        applyHighestPriorityCamera()
        refreshCameras()
    }

    func isIgnored(_ camera: CameraDevice) -> Bool {
        priorityManager.isIgnored(camera)
    }

    func setIgnored(_ camera: CameraDevice, ignored: Bool) {
        priorityManager.setIgnored(camera, ignored: ignored)
        refreshCameras()
        applyHighestPriorityCamera()
    }

    func forgetCamera(_ camera: CameraDevice) {
        priorityManager.forgetCamera(camera.uniqueID)
        refreshCameras()
    }

    func toggleEditMode() {
        isEditMode.toggle()
        refreshCameras()
    }

    /// Hands the system back to macOS's own camera ordering.
    func resetSystemPreference() {
        service.clearPreferred()
        refreshCameras()
    }

    // MARK: - Auto-switching

    private func applyHighestPriorityCamera() {
        guard let top = topPriorityCamera else { return }
        selectedCameraID = top.uniqueID
        guard top.uniqueID != service.currentPreferredUniqueID else {
            recordState(applied: top.name)
            return
        }
        service.setPreferred(uniqueID: top.uniqueID)
        currentPreferredID = service.currentPreferredUniqueID
        recordState(applied: top.name)
    }

    /// Records what the app believes it has set, so the camera side can be
    /// checked from outside the app - the system preference itself is only
    /// readable by a process that already has camera access.
    private func recordState(applied: String) {
        let defaults = UserDefaults.standard
        defaults.set(applied, forKey: "lastAppliedCamera")
        defaults.set(currentPreferredID ?? "none", forKey: "lastSystemPreferredCameraID")
        defaults.set(Date(), forKey: "lastAppliedCameraAt")
        let state: String
        switch authState {
        case .authorized: state = "authorized"
        case .denied: state = "denied"
        case .notDetermined: state = "notDetermined"
        }
        defaults.set(state, forKey: "cameraAuthState")
    }

    private func setupListeners() {
        service.onDevicesChanged = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshCameras()
                self.applyHighestPriorityCamera()
            }
        }
        service.onPreferredCameraChanged = { [weak self] in
            Task { @MainActor in
                self?.currentPreferredID = self?.service.currentPreferredUniqueID
            }
        }
        service.startListening()
    }
}
