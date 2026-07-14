import Combine
import SwiftUI

/// Player transport: play/pause/stop, seek, time labels, master volume,
/// plus the "Separate Tracks", "Detect Key & BPM", and auto-separate controls.
struct TransportBarView: View {
    @Environment(AppState.self) private var appState

    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @State private var displayedTime: TimeInterval = 0

    private let clock = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private var engine: AudioPlayerEngine { appState.playerEngine }

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.media?.title ?? "")
                        .font(.headline)
                        .lineLimit(1)
                    Text("5 Stems · Vocals / Drums / Bass / Piano / Other")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Automatically separate after loading", isOn: $appState.autoSeparate)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }

            // Seek + time
            HStack(spacing: 10) {
                Text(Self.timeString(isScrubbing ? scrubValue : displayedTime))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 46, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubValue : displayedTime },
                        set: { scrubValue = $0 }),
                    in: 0...max(engine.duration, 0.01)
                ) { editing in
                    if editing {
                        scrubValue = displayedTime
                        isScrubbing = true
                    } else {
                        engine.seek(to: scrubValue)
                        displayedTime = scrubValue
                        isScrubbing = false
                    }
                }

                Text(Self.timeString(engine.duration))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 46, alignment: .leading)
            }

            HStack(spacing: 16) {
                // Transport buttons
                HStack(spacing: 10) {
                    Button {
                        engine.state == .playing ? engine.pause() : engine.play()
                    } label: {
                        Image(systemName: engine.state == .playing ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 28)
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    .help(engine.state == .playing ? "Pause" : "Play")

                    Button {
                        engine.stop()
                        displayedTime = 0
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.title3)
                    }
                    .help("Stop")
                }
                .buttonStyle(.borderless)

                // Master volume
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.3")
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(engine.masterVolume) },
                            set: { engine.masterVolume = Float($0) }),
                        in: 0...1)
                    .frame(width: 120)
                }
                .help("Master volume")

                Spacer()

                Button {
                    appState.detectKeyAndBPM()
                } label: {
                    if appState.isAnalyzing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Analyzing…")
                        }
                    } else {
                        Label("Detect Key & BPM", systemImage: "waveform.badge.magnifyingglass")
                    }
                }
                .disabled(appState.isAnalyzing)

                if !appState.mixer.isSeparated {
                    Button {
                        appState.separateStems()
                    } label: {
                        Label("Separate Tracks", systemImage: "square.stack.3d.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!appState.toolLocator.toolSet.hasDemucs)
                    .help(appState.toolLocator.toolSet.hasDemucs
                          ? "Split the song into Vocals / Drums / Bass / Piano / Other"
                          : "Demucs is not installed — open Setup")
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .onReceive(clock) { _ in
            if !isScrubbing {
                displayedTime = engine.currentTime
            }
        }
    }

    static func timeString(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
