import Foundation
import AVFoundation
import AppKit
import IOKit

/// Thin wrapper around AVFoundation's camera discovery and the system-wide
/// preferred-camera setting introduced in macOS 14.
///
/// macOS has no "default camera" the way it has a default audio device. What it
/// does have is `AVCaptureDevice.userPreferredCamera`: a persisted, system-wide
/// hint that every app using `AVCaptureDevice.systemPreferredCamera` or
/// `AVCaptureDevice.default(for: .video)` picks up. Writing that value is how
/// this app expresses camera priority.
final class CameraService: NSObject {
    /// Fired when cameras are connected/disconnected, suspended/resumed, or the
    /// discovery list changes.
    var onDevicesChanged: (() -> Void)?
    /// Fired when the system's preferred camera changes (by us, or by another app).
    var onPreferredCameraChanged: (() -> Void)?

    private var discoverySession: AVCaptureDevice.DiscoverySession?
    private var devicesObservation: NSKeyValueObservation?
    /// One observation per camera, keyed by uniqueID, watching its suspended
    /// flag. The flag has no notification of its own; AVFoundation documents
    /// key-value observing as the way to hear it change.
    private var suspendObservations: [String: NSKeyValueObservation] = [:]
    private var isObservingPreferred = false
    private var lidNotifyPort: IONotificationPortRef?
    private var lidNotification: io_object_t = 0
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

    /// Every camera macOS lists, including ones it has switched off. A camera
    /// is reported suspended when AVFoundation says so, and the built-in one
    /// also whenever the lid is closed: with the lid down it stays in the list
    /// as "connected", but it sees nothing and macOS will not hand it to apps,
    /// so treating it as first choice left the whole system on a camera that
    /// wasn't there.
    func getDevices() -> [CameraDevice] {
        let session = ensureDiscoverySession()
        let lidClosed = Self.isLidClosed
        return session.devices.map { device in
            let dependsOnLid = device.deviceType == .builtInWideAngleCamera
            return CameraDevice(
                uniqueID: device.uniqueID,
                name: device.localizedName,
                kind: CameraKind.classify(device),
                isSuspended: device.isSuspended || (lidClosed && dependsOnLid)
            )
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

    // MARK: - Lid

    /// Whether the MacBook's lid is closed, straight from the power manager.
    /// AVFoundation's own suspended flag is the first signal; this is the
    /// second, for the moments and machines where that flag lags or stays
    /// clear.
    static var isLidClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) else {
            return false
        }
        return (value.takeRetainedValue() as? Bool) ?? false
    }

    // MARK: - Listening

    func startListening() {
        let session = ensureDiscoverySession()

        devicesObservation = session.observe(\.devices, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.watchSuspension()
                self?.onDevicesChanged?()
            }
        }
        watchSuspension()
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
        let center = NotificationCenter.default
        for name in [
            AVCaptureDevice.wasConnectedNotification,
            AVCaptureDevice.wasDisconnectedNotification,
            // Closing the lid is also a display change; a second route to the
            // same re-check, in case the suspension flag lags behind.
            NSApplication.didChangeScreenParametersNotification
        ] {
            center.addObserver(self, selector: #selector(deviceChanged), name: name, object: nil)
        }
        startLidListener()
    }

    @objc private func deviceChanged() {
        DispatchQueue.main.async { [weak self] in self?.onDevicesChanged?() }
    }

    /// Follows the suspended flag of every camera currently listed: the
    /// built-in one flips it when the lid closes and opens without ever
    /// leaving the list, so the connect/disconnect notices never fire.
    private func watchSuspension() {
        let devices = ensureDiscoverySession().devices
        let present = Set(devices.map(\.uniqueID))
        for gone in suspendObservations.keys where !present.contains(gone) {
            suspendObservations[gone]?.invalidate()
            suspendObservations[gone] = nil
        }
        for device in devices where suspendObservations[device.uniqueID] == nil {
            suspendObservations[device.uniqueID] = device.observe(\.isSuspended, options: [.new]) { [weak self] _, _ in
                self?.deviceChanged()
            }
        }
    }

    /// The power manager tells interested processes when the lid state
    /// changes, among other things. Any message from it is cheap to answer
    /// with a fresh look at the cameras.
    private func startLidListener() {
        guard lidNotifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else {
            IONotificationPortDestroy(port)
            return
        }
        defer { IOObjectRelease(service) }

        let callback: IOServiceInterestCallback = { context, _, _, _ in
            guard let context else { return }
            Unmanaged<CameraService>.fromOpaque(context).takeUnretainedValue().deviceChanged()
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(port, service, kIOGeneralInterest, callback, context, &lidNotification)
        if result == KERN_SUCCESS {
            lidNotifyPort = port
        } else {
            IONotificationPortDestroy(port)
        }
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
        suspendObservations.values.forEach { $0.invalidate() }
        if isObservingPreferred {
            for keyPath in Self.preferredKeyPaths {
                AVCaptureDevice.self.removeObserver(self, forKeyPath: keyPath)
            }
        }
        NotificationCenter.default.removeObserver(self)
        if lidNotification != 0 { IOObjectRelease(lidNotification) }
        if let port = lidNotifyPort { IONotificationPortDestroy(port) }
    }
}
