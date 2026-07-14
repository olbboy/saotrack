import SwiftUI

/// The multi-track mixer: one strip per stem after separation, or a hint
/// card before it.
struct MixerView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.mixer.isSeparated {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Mixer")
                        .font(.headline)
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
