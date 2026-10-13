import SwiftUI

/// Play/pause, scrubber, position, length and the clock time at the playback position.
/// Used under a transcript and for previewing a session on the recorder.
struct PlayerBar: View {
    let player: PlayerModel
    /// Clock time at a position in seconds.
    let clock: (Double) -> String
    var title: String?
    /// A highlighted range under the scrubber (the part of a session that will be imported).
    var marked: ClosedRange<Double>?
    var onClose: (() -> Void)?
    @State private var scrubPosition: Double?

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                    player.togglePlayback()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.title3)
                .keyboardShortcut(.space, modifiers: [])
                .frame(width: 24)
                .accessibilityIdentifier("play")

                if let title {
                    Text(title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .fixedSize()
                }
                let position = scrubPosition ?? player.currentSeconds
                Text(Format.position(position))
                    .monospacedDigit()
                    .frame(minWidth: 52, alignment: .trailing)
                Slider(value: Binding(get: { position }, set: { scrubPosition = $0 }),
                       in: 0...max(player.durationSeconds, 1)) { editing in
                    if !editing, let target = scrubPosition {
                        player.seek(to: target)
                        scrubPosition = nil
                    }
                }
                .controlSize(.small)
                .overlay(alignment: .bottom) {
                    if let marked, player.durationSeconds > 0 {
                        GeometryReader { geometry in
                            let width = geometry.size.width, total = player.durationSeconds
                            Capsule()
                                .fill(Color.orange)
                                .frame(width: max(2, width * (marked.upperBound - marked.lowerBound) / total), height: 3)
                                .offset(x: width * marked.lowerBound / total)
                        }
                        .frame(height: 3)
                        .offset(y: 7)
                        .allowsHitTesting(false)
                        .help("The part that will be imported")
                    }
                }
                .accessibilityLabel("Playback position")
                Text(Format.position(player.durationSeconds))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(clock(position))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .trailing)
                    .help("Clock time at the playback position")
                if let onClose {
                    Button("Close", systemImage: "xmark.circle.fill", action: onClose)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Stop the preview")
                        .accessibilityIdentifier("close-preview")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .disabled(!player.isAvailable)
            .help(player.isAvailable ? "" : "The audio file is not available.")
        }
        .background(.bar)
    }
}
