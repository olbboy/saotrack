import SwiftUI

/// One mixer channel strip: stem name, mute/solo, volume, export.
struct TrackStripView: View {
    @Environment(AppState.self) private var appState
    let track: StemTrack

    private var mixer: MixerViewModel { appState.mixer }

    private var isAudible: Bool {
        mixer.effectiveGain(for: track) > 0
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: track.kind?.symbolName ?? "music.note")
                .font(.title3)
                .foregroundStyle(isAudible ? Color.accentColor : .secondary)

            Text(track.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

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
}
