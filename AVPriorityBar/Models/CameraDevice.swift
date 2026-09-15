import Foundation
import AVFoundation

/// A video capture device, connected or remembered from a previous session.
struct CameraDevice: Identifiable, Equatable, Hashable {
    /// AVCaptureDevice.uniqueID - stable across reconnects, used as the persistence key.
    let uniqueID: String
    let name: String
    let kind: CameraKind
    var isConnected: Bool = true

    var id: String { uniqueID }

    static func disconnected(uniqueID: String, name: String, kind: CameraKind) -> CameraDevice {
        CameraDevice(uniqueID: uniqueID, name: name, kind: kind, isConnected: false)
    }
}

/// Coarse classification of a camera, used only for the row icon and tooltips.
enum CameraKind: String, Codable {
    case builtIn
    case external
    case continuity
    case deskView
    case virtual
    case unknown

    var icon: String {
        switch self {
        case .builtIn: return "laptopcomputer"
        case .external: return "web.camera"
        case .continuity: return "iphone"
        case .deskView: return "rectangle.on.rectangle.angled"
        case .virtual: return "square.stack.3d.up"
        case .unknown: return "camera"
        }
    }

    var label: String {
        switch self {
        case .builtIn: return "Built-in"
        case .external: return "External"
        case .continuity: return "iPhone"
        case .deskView: return "Desk View"
        case .virtual: return "Virtual"
        case .unknown: return "Camera"
        }
    }

    /// Longer description, shown on hover - "Desk View" in particular means
    /// nothing until someone explains it.
    var explanation: String {
        switch self {
        case .builtIn: return "Built-in camera"
        case .external: return "External camera"
        case .continuity: return "Continuity Camera - your iPhone used as a webcam"
        case .deskView: return "Desk View - a second, top-down view of your desk, cropped out of the wide camera"
        case .virtual: return "Virtual camera - a software feed from another app, not real hardware"
        case .unknown: return "Camera"
        }
    }

    static func classify(_ device: AVCaptureDevice) -> CameraKind {
        switch device.deviceType {
        case .builtInWideAngleCamera:
            return .builtIn
        case .continuityCamera:
            return .continuity
        case .deskViewCamera:
            return .deskView
        default:
            break
        }
        // Virtual cameras (OBS, Camo, Elgato, Snap) register as external hardware
        // but are software passthroughs, so name matching is the only signal.
        let lowered = device.localizedName.lowercased()
        for hint in ["obs", "virtual", "camo", "snap camera", "ndi", "loopback", "mmhmm", "ecamm"] {
            if lowered.contains(hint) { return .virtual }
        }
        return .external
    }

    /// Ranking used to seed the list on a first run, before the user has set an
    /// order: real hardware first, software cameras last.
    var defaultRank: Int {
        switch self {
        case .external: return 0
        case .builtIn: return 1
        case .continuity: return 2
        case .deskView: return 3
        case .virtual: return 4
        case .unknown: return 5
        }
    }}

/// Camera permission state, surfaced in the UI so a denied prompt is explainable.
enum CameraAuthState {
    case authorized
    case notDetermined
    case denied
}
