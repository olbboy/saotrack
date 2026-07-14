import SwiftUI

/// The multi-track mixer: one strip per stem after separation, or a hint
/// card before it.
@MainActor
struct MixerView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.mixer.isSeparated {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Mixer")
                            .font(.headline)
                        Spacer()
                        Button("Karaoke") { appState.mixer.applyKaraokePreset() }
                            .help("Mute the vocals, keep the band")
                        Button("Acapella") { appState.mixer.applyAcapellaPreset() }
                            .help("Solo the vocals")
                        Button("Reset") { appState.mixer.resetMix() }
                            .help("Full volume, center pan, no mute/solo")
                    }
                    .controlSize(.small)
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(appState.mixer.tracks) { track in
                            TrackStripView(track: track)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(16)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(.secondary)
                    Text("Separate the track to unlock the multi-track mixer: mute the vocals for karaoke, solo the drums, rebalance the song, and export stems.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(16)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
