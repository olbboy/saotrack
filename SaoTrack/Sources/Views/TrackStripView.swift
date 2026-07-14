import SwiftUI

/// One mixer channel strip: stem name, level meter, volume, pan,
/// mute/solo, export.
@MainActor
struct TrackStripView: View {
    @Environment(AppState.self) private var appState
    let track: StemTrack

    private var mixer: MixerViewModel { appState.mixer }

    private var isAudible: Bool {
        mixer.effectiveGain(for: track) > 0
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: track.kind?.symbolName ?? "music.note")
                .font(.title3)
                .foregroundStyle(isAudible ? Color.accentColor : .secondary)

            Text(track.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            LevelMeterView(level: appState.playerEngine.trackLevels[track.id] ?? 0)
                .frame(maxWidth: 110)

            Slider(
                value: Binding(
                    get: { Double(track.volume) },
                    set: { mixer.setVolume(Float($0), for: track.id) }),
                in: 0...1)
            .frame(maxWidth: 110)
            .help("Volume: \(Int(track.volume * 100))%")

            Text("\(Int(track.volume * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            // Pan
            HStack(spacing: 4) {
                Text("L")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Slider(
                    value: Binding(
                        get: { Double(track.pan) },
                        set: { mixer.setPan(Float($0), for: track.id) }),
                    in: -1...1)
                .controlSize(.mini)
                Text("R")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 110)
            .help(panHelp)

            HStack(spacing: 6) {
                Toggle("M", isOn: Binding(
                    get: { track.isMuted },
                    set: { _ in mixer.toggleMute(for: track.id) }))
                .toggleStyle(.button)
                .tint(.red)
                .help("Mute")

                Toggle("S", isOn: Binding(
                    get: { track.isSoloed },
                    set: { _ in mixer.toggleSolo(for: track.id) }))
                .toggleStyle(.button)
                .tint(.yellow)
                .help("Solo")
            }
            .font(.caption.bold())

            Button {
                appState.exportSingleStem(track)
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.caption)
            }
            .controlSize(.small)
            .help("Export this stem as \(appState.exportFormat.rawValue)")
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isAudible ? Color.accentColor.opacity(0.06) : Color.secondary.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.2)))
        .opacity(isAudible ? 1 : 0.6)
        .animation(.easeInOut(duration: 0.15), value: isAudible)
    }

    private var panHelp: String {
        if track.pan == 0 { return "Pan: center" }
        let percent = Int(abs(track.pan) * 100)
        return track.pan < 0 ? "Pan: \(percent)% left" : "Pan: \(percent)% right"
    }
}

/// Thin horizontal peak meter driven by the engine's render taps.
struct LevelMeterView: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(LinearGradient(
                        colors: [.green, .yellow, .orange],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: geometry.size.width * CGFloat(min(1, max(0, level))))
            }
        }
        .frame(height: 4)
        .animation(.linear(duration: 0.1), value: level)
    }
}
