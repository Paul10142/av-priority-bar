import Foundation
import AVFoundation

/// Thin wrapper around AVFoundation's camera discovery and the system-wide
/// preferred-camera setting introduced in macOS 14.
///
/// macOS has no "default camera" the way it has a default audio device. What it
/// does have is `AVCaptureDevice.userPreferredCamera`: a persisted, system-wide
/// hint that every app using `AVCaptureDevice.systemPreferredCamera` or
/// `AVCaptureDevice.default(for: .video)` picks up. Writing that value is how
/// this app expresses camera priority.
final class CameraService: NSObject {
    /// Fired when cameras are connected/disconnected or the discovery list changes.
    var onDevicesChanged: (() -> Void)?
    /// Fired when the system's preferred camera changes (by us, or by another app).
    var onPreferredCameraChanged: (() -> Void)?

    private var discoverySession: AVCaptureDevice.DiscoverySession?
    private var devicesObservation: NSKeyValueObservation?
    private var isObservingPreferred = false
    private static let preferredKeyPaths = ["systemPreferredCamera", "userPreferredCamera"]

    private static let deviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera,
        .external,
        .continuityCamera,
        .deskViewCamera
    ]

    // MARK: - Authorization

    var authState: CameraAuthState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: - Discovery

    func getDevices() -> [CameraDevice] {
        let session = ensureDiscoverySession()
        return session.devices.map {
            CameraDevice(uniqueID: $0.uniqueID, name: $0.localizedName, kind: CameraKind.classify($0))
        }
    }

    func avDevice(forUniqueID uniqueID: String) -> AVCaptureDevice? {
        ensureDiscoverySession().devices.first { $0.uniqueID == uniqueID }
    }

    // MARK: - Preferred camera

    /// The camera macOS currently hands to apps that ask for the default.
    ///
    /// `systemPreferredCamera` reads back as nil until the app has been granted
    /// camera access, so the value this app itself wrote is the fallback - that
    /// one is readable either way, and keeps the "Active" marker honest before
    /// any permission has been granted.
    var currentPreferredUniqueID: String? {
        AVCaptureDevice.systemPreferredCamera?.uniqueID ?? AVCaptureDevice.userPreferredCamera?.uniqueID
    }

    /// Writes the system-wide user preference. Takes effect immediately for apps
    /// that follow `systemPreferredCamera`; apps that pin their own camera ignore it.
    @discardableResult
    func setPreferred(uniqueID: String) -> Bool {
        guard let device = avDevice(forUniqueID: uniqueID) else { return false }
        AVCaptureDevice.userPreferredCamera = device
        return true
    }

    /// Clears the user preference and lets macOS fall back to its own ordering.
    func clearPreferred() {
        AVCaptureDevice.userPreferredCamera = nil
    }

    // MARK: - Listening

    func startListening() {
        let session = ensureDiscoverySession()

        devicesObservation = session.observe(\.devices, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.onDevicesChanged?() }
        }
        // `systemPreferredCamera` is a class property, so it takes string-keyed KVO
        // on the class object rather than a Swift key-path observation.
        if !isObservingPreferred {
            for keyPath in Self.preferredKeyPaths {
                AVCaptureDevice.self.addObserver(self, forKeyPath: keyPath, options: [.new], context: nil)
            }
            isObservingPreferred = true
        }

        // Belt and braces: KVO on `devices` can miss a Continuity Camera that
        // appears and vanishes quickly, the notifications do not.
        NotificationCenter.default.addObserver(
            self, selector: #selector(deviceChanged),
            name: AVCaptureDevice.wasConnectedNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(deviceChanged),
            name: AVCaptureDevice.wasDisconnectedNotification, object: nil
        )
    }

    @objc private func deviceChanged() {
        DispatchQueue.main.async { [weak self] in self?.onDevicesChanged?() }
    }

    private func ensureDiscoverySession() -> AVCaptureDevice.DiscoverySession {
        if let session = discoverySession { return session }
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        discoverySession = session
        return session
    }

    override func observeValue(
        forKeyPath keyPath: String?, of object: Any?,
        change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
    ) {
        guard let keyPath, Self.preferredKeyPaths.contains(keyPath) else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        DispatchQueue.main.async { [weak self] in self?.onPreferredCameraChanged?() }
    }

    deinit {
        devicesObservation?.invalidate()
        if isObservingPreferred {
            for keyPath in Self.preferredKeyPaths {
                AVCaptureDevice.self.removeObserver(self, forKeyPath: keyPath)
            }
        }
        NotificationCenter.default.removeObserver(self)
    }
}
