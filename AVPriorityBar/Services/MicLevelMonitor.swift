import AVFoundation

/// Live input level from the current default microphone - the "is this thing on?"
/// check. Runs only while the audio tab is on screen.
@MainActor
final class MicLevelMonitor: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var permissionDenied = false

    private var engine: AVAudioEngine?

    func start() {
        guard engine == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            attach()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted { self.attach() } else { self.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        level = 0
    }

    /// Rebuilds the tap after the default input device changes.
    func restart() {
        guard engine != nil else { return }
        stop()
        start()
    }

    private func attach() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            // Plain RMS - Accelerate can't be imported with the Command Line
            // Tools toolchain, and a 1024-sample loop costs nothing.
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var sum: Float = 0
            for index in 0..<count {
                let sample = channel[index]
                sum += sample * sample
            }
            let rms = (sum / Float(count)).squareRoot()
            // Map roughly -50dB..0dB onto 0..1 so quiet speech still moves it.
            let db = 20 * log10(max(rms, 0.000_001))
            let scaled = max(0, min(1, (db + 50) / 50))
            DispatchQueue.main.async {
                self?.level = self?.level ?? 0 > scaled
                    ? (self?.level ?? 0) * 0.7 + scaled * 0.3   // fall back smoothly
                    : scaled                                     // rise immediately
            }
        }

        do {
            try engine.start()
            self.engine = engine
        } catch {
            self.engine = nil
        }
    }
}
