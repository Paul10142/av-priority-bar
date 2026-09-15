import SwiftUI
import AVFoundation

/// Contents of the camera view: live preview, the priority list, and the note
/// about how far a system-wide camera preference reaches. The header row and
/// scrolling are owned by MenuBarView, same as the audio sections.
struct CameraContentView: View {
    @EnvironmentObject var cameraManager: CameraManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CameraPreviewPanel()

            if cameraManager.isOverridden {
                CameraOverrideNoticeView()
            }

            // Camera names are readable without permission, but macOS only
            // honours a written camera preference from an app that has been
            // granted access - so the list always shows and the banner explains
            // why nothing would happen yet.
            if cameraManager.authState == .denied {
                CameraPermissionDeniedView()
            } else if cameraManager.authState == .notDetermined {
                CameraPermissionPromptView()
            }

            CameraSectionView()

            CameraScopeNoteView()
        }
    }
}

struct CameraSectionView: View {
    @EnvironmentObject var cameraManager: CameraManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                Text("Cameras")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }

            if cameraManager.cameras.isEmpty {
                Text("No cameras found")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary.opacity(0.7))
                    .italic()
                    .padding(.vertical, 10)
            } else {
                CameraListView(
                    cameras: cameraManager.cameras,
                    onMove: cameraManager.moveCamera,
                    onSelect: cameraManager.selectCamera
                )
            }

            if !cameraManager.ignoredCameras.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ignored")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .padding(.top, 6)
                    ForEach(cameraManager.ignoredCameras) { camera in
                        IgnoredCameraRow(camera: camera)
                    }
                }
            }
        }
    }
}

struct CameraListView: View {
    let cameras: [CameraDevice]
    let onMove: (IndexSet, Int) -> Void
    let onSelect: (CameraDevice) -> Void

    @State private var draggingIndex: Int? = nil
    @State private var targetIndex: Int? = nil

    private let rowHeight: CGFloat = 32

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(cameras.enumerated()), id: \.element.id) { index, camera in
                DraggableCameraRow(
                    camera: camera,
                    index: index,
                    cameraCount: cameras.count,
                    rowHeight: rowHeight,
                    isDragging: draggingIndex == index,
                    isDropTarget: isDropTarget(for: index),
                    isDropTargetBelow: isDropTargetBelow(for: index),
                    onSelect: { onSelect(camera) },
                    onDragStarted: { draggingIndex = index },
                    onTargetChanged: { targetIndex = $0 },
                    onDragEnded: { performMove(fromIndex: index) }
                )
                .zIndex(draggingIndex == index ? 100 : 0)
            }
        }
    }

    private func isDropTarget(for index: Int) -> Bool {
        guard let target = targetIndex, let dragging = draggingIndex else { return false }
        return target == index && dragging != index && dragging != index - 1
    }

    private func isDropTargetBelow(for index: Int) -> Bool {
        guard let target = targetIndex, let dragging = draggingIndex else { return false }
        return target == cameras.count && index == cameras.count - 1 && dragging != cameras.count - 1
    }

    private func performMove(fromIndex: Int) {
        if let target = targetIndex, target != fromIndex {
            onMove(IndexSet(integer: fromIndex), target)
        }
        draggingIndex = nil
        targetIndex = nil
    }
}

struct DraggableCameraRow: View {
    @EnvironmentObject var cameraManager: CameraManager
    let camera: CameraDevice
    let index: Int
    let cameraCount: Int
    let rowHeight: CGFloat
    let isDragging: Bool
    var isDropTarget: Bool = false
    var isDropTargetBelow: Bool = false
    let onSelect: () -> Void
    let onDragStarted: () -> Void
    let onTargetChanged: (Int?) -> Void
    let onDragEnded: () -> Void

    @State private var isHovering = false
    @State private var lastReportedTarget: Int? = nil

    private var isDisconnected: Bool { !cameraManager.isConnected(camera) }
    private var isActive: Bool { camera.uniqueID == cameraManager.currentPreferredID && !isDisconnected }
    private var isIgnored: Bool { cameraManager.isIgnored(camera) }

    private func calculateTarget(offset: CGFloat) -> Int? {
        let rowsOffset = Int(round(offset / rowHeight))
        var newTarget = index + rowsOffset
        newTarget = max(0, min(cameraCount, newTarget))
        if newTarget == index || newTarget == index + 1 { return nil }
        return newTarget
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 36, height: rowHeight)
                    .opacity(isHovering || isDragging ? 1 : 0)
                    .scaleEffect(isHovering || isDragging ? 1 : 0.8)

                Group {
                    if isActive {
                        Text("Active")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.accentColor)
                    } else {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                }
                .opacity(isHovering || isDragging ? 0 : 1)
                .scaleEffect(isHovering || isDragging ? 0.8 : 1)
            }
            .frame(width: 36)
            .animation(.easeInOut(duration: 0.12), value: isHovering)
            .animation(.easeInOut(duration: 0.12), value: isDragging)

            HStack(spacing: 8) {
                Image(systemName: camera.kind.icon)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                    .help(camera.kind.explanation)

                Text(camera.name)
                    .font(.system(size: 13))
                    .strikethrough(isIgnored, color: .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(isDisconnected || isIgnored ? .secondary : .primary)
                    .help(camera.name)

                if isDisconnected {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                    if let lastSeen = cameraManager.lastSeen(camera) {
                        Text(lastSeen)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }

                Spacer(minLength: 12)

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                        .font(.system(size: 15))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isActive)

            ZStack {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .frame(width: 28, height: 28)
                    .opacity(0)

                if isHovering && !isDragging {
                    Menu {
                        if !isDisconnected {
                            Button {
                                cameraManager.selectCamera(camera)
                            } label: {
                                Label("Use This Camera Now", systemImage: "checkmark.circle")
                            }
                            Divider()
                        }
                        Button {
                            cameraManager.setIgnored(camera, ignored: !isIgnored)
                        } label: {
                            if isIgnored {
                                Label("Stop Ignoring", systemImage: "eye")
                            } else {
                                Label("Ignore This Camera", systemImage: "eye.slash")
                            }
                        }
                        if isDisconnected {
                            Divider()
                            Button(role: .destructive) {
                                cameraManager.forgetCamera(camera)
                            } label: {
                                Label("Forget Camera", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .frame(width: 32)
            .animation(.easeInOut(duration: 0.12), value: isHovering)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .opacity(isDragging ? 0.5 : (isDisconnected || isIgnored ? 0.6 : 1.0))
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? Color.accentColor.opacity(0.12) : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isActive ? Color.accentColor.opacity(0.8) : Color.clear, lineWidth: 1.5)
        )
        .overlay(alignment: .top) {
            if isDropTarget {
                DropIndicatorLine().offset(y: -5)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .overlay(alignment: .bottom) {
            if isDropTargetBelow {
                DropIndicatorLine().offset(y: 5)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isDragging ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .scaleEffect(isDragging ? 1.02 : 1.0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
            // Hovering previews the camera without touching priority or the
            // active choice - look first, commit only if you click.
            if hovering {
                cameraManager.hoveredCameraID = isDisconnected ? nil : camera.uniqueID
            } else if cameraManager.hoveredCameraID == camera.uniqueID {
                cameraManager.hoveredCameraID = nil
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragging)
        .animation(.easeInOut(duration: 0.1), value: isDropTarget)
        .animation(.easeInOut(duration: 0.1), value: isDropTargetBelow)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isDisconnected { onSelect() }
        }
        .gesture(
            DragGesture(minimumDistance: 5)
                .onChanged { value in
                    if !isDragging { onDragStarted() }
                    let newTarget = calculateTarget(offset: value.translation.height)
                    if newTarget != lastReportedTarget {
                        lastReportedTarget = newTarget
                        onTargetChanged(newTarget)
                    }
                }
                .onEnded { _ in
                    lastReportedTarget = nil
                    onDragEnded()
                }
        )
    }
}

struct IgnoredCameraRow: View {
    @EnvironmentObject var cameraManager: CameraManager
    let camera: CameraDevice
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: camera.kind.icon)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 18)

            Text(camera.name)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if isHovering {
                Button {
                    cameraManager.setIgnored(camera, ignored: false)
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop ignoring")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
    }
}

/// Shown when something else has taken the system preference away from the
/// top-ranked camera, with a one-click way to take it back.
struct CameraOverrideNoticeView: View {
    @EnvironmentObject var cameraManager: CameraManager

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.orange)
            Text("Another app changed the active camera")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer(minLength: 6)
            if let top = cameraManager.topPriorityCamera {
                Button("Restore") {
                    cameraManager.selectCamera(top)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.accentColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}

// MARK: - Permission states

struct CameraPermissionPromptView: View {
    @EnvironmentObject var cameraManager: CameraManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Camera access needed")
                .font(.system(size: 13, weight: .semibold))
            Text("macOS only reveals camera names to apps you've allowed. Nothing is recorded or previewed - the access is used to list your cameras and set which one apps get by default.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Allow Camera Access") {
                cameraManager.requestAccessIfNeeded()
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

struct CameraPermissionDeniedView: View {
    @EnvironmentObject var cameraManager: CameraManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Camera access is off")
                .font(.system(size: 13, weight: .semibold))
            Text("The order below is saved but macOS won\'t act on it. Turn on AV Priority Bar under Privacy & Security → Camera, then reopen this menu.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy Settings") {
                cameraManager.openPrivacySettings()
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

/// The honest small print: this sets a system-wide preference, not a lock.
struct CameraScopeNoteView: View {
    @EnvironmentObject var cameraManager: CameraManager
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: "info.circle").font(.system(size: 11))
                    Text("Which apps follow this?")
                        .font(.system(size: 11))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text("macOS has no single \"default camera\" switch the way it does for sound. This sets the system-wide preferred camera, which apps pick up when they ask macOS for the default - FaceTime, Photo Booth and most apps that don't remember their own choice.")
                    Text("Apps with their own camera menu (Zoom, Teams, OBS, Meet in a browser) keep using whatever you last picked in them. Change it there once and they'll stay put.")
                    Button("Reset to macOS default") {
                        cameraManager.resetSystemPreference()
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }
        }
        .padding(.top, 4)
    }
}
