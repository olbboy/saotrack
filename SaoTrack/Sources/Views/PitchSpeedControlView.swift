import SwiftUI

/// Popover content: live transpose (±12 semitones) and playback speed
/// (0.5×–1.5×). Both apply to playback only, never to exports.
@MainActor
struct PitchSpeedControlView: View {
    @Environment(AppState.self) private var appState

    private var engine: AudioPlayerEngine { appState.playerEngine }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controlRow(
                title: "Pitch",
                valueLabel: Self.pitchLabel(engine.pitchSemitones),
                isNeutral: engine.pitchSemitones == 0,
                reset: { engine.pitchSemitones = 0 }
            ) {
                Slider(
                    value: Binding(
                        get: { Double(engine.pitchSemitones) },
                        set: { engine.pitchSemitones = Float($0.rounded()) }),
                    in: -12...12, step: 1)
            }
            rangeCaption(low: "-12 st", high: "+12 st")

            Divider()

            controlRow(
                title: "Speed",
                valueLabel: Self.speedLabel(engine.playbackRate),
                isNeutral: abs(engine.playbackRate - 1) < 0.001,
                reset: { engine.playbackRate = 1 }
            ) {
                Slider(
                    value: Binding(
                        get: { Double(engine.playbackRate) },
                        set: { engine.playbackRate = Float(($0 * 20).rounded() / 20) }),
                    in: 0.5...1.5)
            }
            rangeCaption(low: "0.5×", high: "1.5×")

            Text("Applies to live playback only — exports keep the original pitch and tempo.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 280)
    }

    private func controlRow<Content: View>(
        title: String,
        valueLabel: String,
        isNeutral: Bool,
        reset: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(valueLabel)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(isNeutral ? .secondary : Color.accentColor)
                Button {
                    reset()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .disabled(isNeutral)
                .help("Reset \(title.lowercased())")
            }
            content()
        }
    }

    private func rangeCaption(low: String, high: String) -> some View {
        HStack {
            Text(low)
            Spacer()
            Text(high)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    static func pitchLabel(_ semitones: Float) -> String {
        let value = Int(semitones)
        return value > 0 ? "+\(value) st" : "\(value) st"
    }

    static func speedLabel(_ rate: Float) -> String {
        String(format: "%.2f×", rate)
    }
}
