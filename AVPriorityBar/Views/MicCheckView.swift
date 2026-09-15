import SwiftUI

/// Bar meter that moves when the current microphone hears something.
struct MicCheckView: View {
    @EnvironmentObject var audioManager: AudioManager
    @StateObject private var monitor = MicLevelMonitor()

    private let barCount = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                Text("Mic check")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                if let name = currentMicName {
                    Text(name)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(name)
                }
            }

            if monitor.permissionDenied {
                Text("Microphone access is off - turn it on in Privacy & Security to see levels.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 2) {
                    ForEach(0..<barCount, id: \.self) { index in
                        let threshold = Float(index + 1) / Float(barCount)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(color(for: index, lit: monitor.level >= threshold))
                            .frame(height: 10)
                    }
                }
                .animation(.easeOut(duration: 0.08), value: monitor.level)
            }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .onChange(of: audioManager.currentInputId) { _, _ in monitor.restart() }
    }

    private var currentMicName: String? {
        audioManager.inputDevices.first { $0.id == audioManager.currentInputId }?.name
    }

    private func color(for index: Int, lit: Bool) -> Color {
        guard lit else { return .primary.opacity(0.12) }
        let fraction = Double(index) / Double(barCount)
        if fraction > 0.9 { return .red }
        if fraction > 0.75 { return .yellow }
        return .green
    }
}
