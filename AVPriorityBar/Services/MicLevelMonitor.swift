import AVFoundation
import AudioToolbox
import CoreAudio

/// Live input level from the active microphone - the "is this thing on?"
/// check. Runs only while the audio tab is on screen.
///
/// It listens through an input-only audio queue bound to one device by UID,
/// deliberately not through AVAudioEngine. The engine opens input and output
/// as a single unit, so whenever the default microphone and speakers are
/// different devices (nearly always) Core Audio builds a private aggregate
/// device - CADefaultDeviceAggregate-<pid>-<n>, a new name every time - to
/// glue them together. That aggregate was the mystery device that kept
/// turning up in this app's own lists, and it runs at the speakers' sample
/// rate, so a microphone that only does 96 kHz (Wave Link's virtual mics)
/// came through it as nothing but zeros. A plain input queue has neither
/// problem: no aggregate is created, and the device runs at its own rate.
@MainActor
final class MicLevelMonitor: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var permissionDenied = false
    /// True when the device is running but has sent nothing but silence for a
    /// few seconds. A quiet room still registers around -60 dB; a virtual
    /// microphone whose source is off, or a hardware mute, sits at the floor.
    /// Worth saying, because the empty meter looks the same either way.
    @Published private(set) var isSilent = false

    private var queue: AudioQueueRef?
    private var meterTimer: Timer?
    private var deviceUID: String?
    private var wantsRunning = false
    private var startedAt: Date?
    private var lastSoundAt: Date?
    private let stats = Stats()

    /// Below this the signal is digital silence, not a quiet room.
    private static let silenceFloorDB: Float = -90
    private static let silenceGrace: TimeInterval = 3

    /// Shared with the audio queue's own thread, hence the lock.
    private final class Stats {
        private let lock = NSLock()
        private var count = 0
        var buffers: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
        func bump() {
            lock.lock(); count += 1; lock.unlock()
        }
        func reset() {
            lock.lock(); count = 0; lock.unlock()
        }
    }

    // MARK: - Control

    /// Starts metering `deviceUID`, or the system default input when nil.
    func start(deviceUID: String?) {
        self.deviceUID = deviceUID
        wantsRunning = true
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            attach()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.wantsRunning else { return }
                    if granted { self.attach() } else { self.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }

    func stop() {
        wantsRunning = false
        detach()
        level = 0
        isSilent = false
    }

    /// Follows the active microphone: a different device, or the same one
    /// after it was unplugged and came back, gets a fresh queue.
    func update(deviceUID: String?) {
        self.deviceUID = deviceUID
        restart()
    }

    /// Rebuilds the queue. Unlike before, a failed start is retried too - the
    /// old guard meant one bad start left the meter dead until the tab closed.
    func restart() {
        guard wantsRunning else { return }
        detach()
        level = 0
        isSilent = false
        start(deviceUID: deviceUID)
    }

    // MARK: - Audio queue

    private func attach() {
        guard queue == nil else { return }
        guard let uid = deviceUID ?? Self.defaultInputUID(),
              let deviceID = Self.deviceID(forUID: uid) else { return }

        // One channel of Float32 at the device's own rate: the queue mixes the
        // channels down and nothing has to be resampled.
        var format = AudioStreamBasicDescription(
            mSampleRate: Self.nominalSampleRate(of: deviceID) ?? 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let callback: AudioQueueInputCallback = { userData, queue, buffer, _, _, _ in
            if let userData {
                Unmanaged<Stats>.fromOpaque(userData).takeUnretainedValue().bump()
            }
            // Hand the buffer straight back; the level comes from the queue's
            // own meter, not from the samples.
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }

        var newQueue: AudioQueueRef?
        let userData = Unmanaged.passUnretained(stats).toOpaque()
        guard AudioQueueNewInput(&format, callback, userData, nil, nil, 0, &newQueue) == noErr,
              let newQueue else { return }

        var deviceName = uid as CFString
        let bound = withUnsafePointer(to: &deviceName) { pointer in
            AudioQueueSetProperty(newQueue, kAudioQueueProperty_CurrentDevice, pointer, UInt32(MemoryLayout<CFString>.size))
        }
        guard bound == noErr else {
            AudioQueueDispose(newQueue, true)
            return
        }

        var metering: UInt32 = 1
        AudioQueueSetProperty(newQueue, kAudioQueueProperty_EnableLevelMetering, &metering, UInt32(MemoryLayout<UInt32>.size))

        // About 20 ms per buffer at 96 kHz, three in flight.
        let frames: UInt32 = 2048
        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(newQueue, frames * format.mBytesPerFrame, &buffer) == noErr, let buffer {
                AudioQueueEnqueueBuffer(newQueue, buffer, 0, nil)
            }
        }

        stats.reset()
        guard AudioQueueStart(newQueue, nil) == noErr else {
            AudioQueueDispose(newQueue, true)
            return
        }
        queue = newQueue
        startedAt = Date()
        lastSoundAt = nil
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 25.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readMeter() }
        }
    }

    private func detach() {
        meterTimer?.invalidate()
        meterTimer = nil
        if let queue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
        }
        queue = nil
        startedAt = nil
        lastSoundAt = nil
    }

    private func readMeter() {
        guard let queue else { return }
        let now = Date()

        // The meter reads as 0 dB until the first buffer has gone through, so
        // it is only trusted once the device has actually delivered something.
        if stats.buffers > 0 {
            var meter = AudioQueueLevelMeterState(mAveragePower: -160, mPeakPower: -160)
            var size = UInt32(MemoryLayout<AudioQueueLevelMeterState>.size)
            if AudioQueueGetProperty(queue, kAudioQueueProperty_CurrentLevelMeterDB, &meter, &size) == noErr {
                // Map roughly -50 dB..0 dB onto 0..1, so quiet speech still moves it.
                let scaled = max(0, min(1, (meter.mAveragePower + 50) / 50))
                level = scaled > level ? scaled : level * 0.7 + scaled * 0.3   // rise at once, fall smoothly
                if meter.mAveragePower > Self.silenceFloorDB { lastSoundAt = now }
            }
        }

        let quietSince = lastSoundAt ?? startedAt ?? now
        isSilent = now.timeIntervalSince(quietSince) > Self.silenceGrace
    }

    // MARK: - Core Audio lookups

    private static func defaultInputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func deviceID(forUID uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name = uid as CFString
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), pointer, &size, &deviceID
            )
        }
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    private static func nominalSampleRate(of deviceID: AudioObjectID) -> Float64? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }
}
