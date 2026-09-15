# AV Priority Bar

<p align="center">
  <img src="icon.png" width="128" height="128" alt="AV Priority Bar Icon">
</p>

A personal fork of [tobi/AudioPriorityBar](https://github.com/tobi/AudioPriorityBar) that adds a **Camera** tab alongside the original audio one.

Audio side: set your preferred order for speakers, headphones and microphones, and the app switches to the highest-priority device that's connected. Camera side: the same idea, applied to the system-wide preferred camera.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## What's different from upstream

- **Two tabs** - Audio and Camera. The Audio tab shows speakers, headphones and microphones together, each list with its own volume slider underneath.
- **Cameras** - priority list, drag to reorder, auto-switch on connect/disconnect, and a live preview. Hovering a camera previews it without changing anything.
- **No manual mode** - clicking a device uses it, dragging reorders it, and auto-switching always follows the order. The original app's hand-raised mode is gone.
- **Menu bar icon reflects state** - a slashed speaker when output is muted, a flashing slashed mic when input is, volume level in the waves otherwise.
- **Builds without Xcode** - `./build.sh` compiles with the Command Line Tools and assembles the .app itself.
- **Own bundle id** (`com.paulclancy.AVPriorityBar`), so it installs alongside the original. Audio settings are imported from the original app on first launch.

## How the camera tab works - and its limits

macOS has no single "default camera" setting the way it has for sound. What it does have, since macOS 14, is a system-wide **preferred camera** (`AVCaptureDevice.userPreferredCamera`). This app writes that value, always pointing it at the highest-priority camera currently connected.

- **Apps that follow it:** anything that asks macOS for the default camera - FaceTime, Photo Booth, and most apps without their own camera picker.
- **Apps that don't:** anything that remembers its own choice - Zoom, Teams, OBS, Google Meet in a browser. Set the camera once inside those apps and they stay put.
- **Camera permission is required.** macOS ignores a camera preference written by an app that hasn't been granted camera access. The app never opens a video stream - the permission exists purely so the preference is honoured. Camera *names* are listed with or without it.

## Features

- **Priority-based auto-switching**: Devices are ranked by priority. When a higher-priority device connects, it automatically becomes active.
- **Separate speaker/headphone modes**: Output devices are categorized as either speakers or headphones, each with their own priority list.
- **Click to use, drag to reorder**: Clicking a device switches to it without changing its rank; only dragging changes priority.
- **Per-section volume**: Speakers, headphones and microphones each get their own slider and mute button, driving that specific device. Devices with no volume control show no slider.
- **Device memory**: Remembers all devices you've ever connected, even when disconnected. Edit mode shows disconnected devices with "last seen" timestamps.
- **Per-category ignore**: Hide devices from specific categories without affecting others.
- **Drag-to-reorder**: Reorder devices by dragging or using up/down arrows.
- **Volume control**: Adjust volume with slider or scroll wheel.
- **Menu bar integration**: Shows current mode icon and volume percentage.

### Camera

- **Priority list**: Drag cameras into the order you want, or click one to move it to the top.
- **Live preview**: A thumbnail of the active camera. This is the only time the app opens a video stream, and the only time the green camera light comes on - it runs while the camera view is open and stops the moment you leave it.
- **Hover to preview**: Pointing at a camera shows it in the preview without selecting it or moving it up the list.
- **Override notice**: If another app changes the active camera, a banner offers to put it back.
- **Ignore and forget**: Hide virtual cameras (OBS, Elgato) from the list, or forget ones you no longer own.
- **Sensible first run**: Before you set an order, real hardware ranks above virtual cameras rather than trusting discovery order.

## Installation

### Requirements
- macOS 13.0 (Ventura) or later

### Build from Source

Xcode is not required - the Command Line Tools are enough:

```bash
./build.sh      # produces dist/AVPriorityBar.app
./install.sh    # builds, copies to /Applications, relaunches
```

`build.sh` compiles every Swift file with `swiftc`, generates the app icon from `icon.png` with `sips`/`iconutil`, assembles the bundle, and ad-hoc signs it. The ad-hoc signature matters: an unsigned bundle gets a new identity on each rebuild, so macOS would re-ask for camera access every time.

It also works around a Command Line Tools bug where `SwiftBridging` is declared in two modulemaps, which otherwise fails every compile. The workaround is a VFS overlay; nothing in the system directory is touched.

`AVPriorityBar.xcodeproj` is kept in sync for anyone who does have Xcode, but it is not the build path this fork is tested with.

## Usage

### Modes

| Tab | Shows |
|-----|-------|
| **Audio** | Speakers, headphones and microphones, each with its own priority list and volume slider |
| **Camera** | Live preview and the camera priority list |

### Managing Priorities

- **Click a device**: Switches to it now. It does not change the priority order.
- **Drag devices**: Reorder by dragging the handle
- **Up/Down arrows**: Fine-tune order on hover

### Device Actions (hover menu)

- **Move to Speakers/Headphones**: Change device category
- **Ignore as [category]**: Hide from current category only
- **Ignore entirely**: Hide from both speaker and headphone lists
- **Forget Device**: Remove disconnected device from memory

### Edit Mode

Click "Edit" in the footer to:
- See all devices ever connected (disconnected ones grayed out)
- Reorder disconnected devices in the priority list
- View "last seen" timestamps
- Forget old devices you no longer use

## How It Works

1. **Device Discovery**: Uses CoreAudio to enumerate audio devices and listen for changes.
2. **Priority Storage**: Device priorities are stored in UserDefaults, keyed by device UID (stable across reconnects).
3. **Auto-Switching**: When devices connect/disconnect, the app automatically selects the highest-priority available device for the current mode.
4. **Categories**: Each output device is assigned to either "speaker" or "headphone" category, with separate priority lists.

## Project Structure

```
AVPriorityBar/
├── AVPriorityBarApp.swift         # App entry, MenuBarExtra, AudioManager
├── Models/
│   ├── AudioDevice.swift          # Device model, OutputCategory enum
│   └── CameraDevice.swift         # Camera model, CameraKind classification
├── Services/
│   ├── AudioDeviceService.swift   # CoreAudio wrapper
│   ├── PriorityManager.swift      # Audio priority persistence
│   ├── CameraService.swift        # AVFoundation discovery + preferred camera
│   ├── CameraPriorityManager.swift# Camera priority persistence
│   ├── CameraManager.swift        # Camera state, auto-switching
│   └── SettingsMigration.swift    # One-time import from the original app
└── Views/
    ├── MenuBarView.swift          # Tabs, shared footer, audio tab
    ├── DeviceListView.swift       # Audio device rows
    └── CameraListView.swift       # Camera tab and rows
```

## Credit

All of the audio functionality is [tobi/AudioPriorityBar](https://github.com/tobi/AudioPriorityBar). This fork adds the camera side and the Xcode-free build.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

Built with SwiftUI and CoreAudio for macOS.
