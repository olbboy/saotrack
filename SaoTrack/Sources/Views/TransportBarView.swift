import Combine
import SwiftUI

/// Player transport: waveform seek, play/pause/stop, ±5 s skip, A–B loop,
/// pitch & speed, master volume, plus "Separate Tracks" and auto-separate.
@MainActor
struct TransportBarView: View {
    @Environment(AppState.self) private var appState

    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @State private var displayedTime: TimeInterval = 0
    @State private var showPitchSpeed = false

    private let clock = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private var engine: AudioPlayerEngine { appState.playerEngine }

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.media?.title ?? "")
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(appState.separationMode.displayName) · \(appState.separationMode.stemSummary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Stems", selection: $appState.separationMode) {
                    ForEach(SeparationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(appState.phase.isBusy)
                .help("How many stems the separation produces")
                Toggle("Automatically separate after loading", isOn: $appState.autoSeparate)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }

            // Waveform (or slider fallback) + time labels
            HStack(spacing: 10) {
                Text(Self.timeString(isScrubbing ? scrubValue : displayedTime))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 46, alignment: .trailing)

                if let samples = appState.waveform {
                    WaveformView(
                        samples: samples,
                        duration: engine.duration,
                        currentTime: displayedTime,
                        loopStart: engine.loopStart,
                        loopEnd: engine.loopEnd,
                        isLoopEnabled: engine.isLoopEnabled
                    ) { target in
                        engine.seek(to: target)
                        displayedTime = target
                    }
                    .frame(height: 52)
                } else {
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
                }

                Text(Self.timeString(engine.duration))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 46, alignment: .leading)
            }

            HStack(spacing: 14) {
                transportButtons

                masterVolume

                Divider().frame(height: 20)

                loopControls

                Divider().frame(height: 20)

                pitchSpeedButton

                Spacer()

                if !appState.mixer.isSeparated || appState.needsReseparation {
                    Button {
                        appState.separateStems()
                    } label: {
                        Label(
                            appState.needsReseparation
                                ? "Re-separate (\(appState.separationMode.displayName))"
                                : "Separate Tracks",
                            systemImage: "square.stack.3d.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!appState.toolLocator.toolSet.hasDemucs)
                    .help(appState.toolLocator.toolSet.hasDemucs
                          ? "Split the song into \(appState.separationMode.stemSummary)"
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

    // MARK: - Transport buttons

    private var transportButtons: some View {
        HStack(spacing: 10) {
            Button {
                engine.skip(by: -5)
            } label: {
                Image(systemName: "gobackward.5")
                    .font(.title3)
            }
            .help("Back 5 seconds")

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

            Button {
                engine.skip(by: 5)
            } label: {
                Image(systemName: "goforward.5")
                    .font(.title3)
            }
            .help("Forward 5 seconds")
        }
        .buttonStyle(.borderless)
    }

    private var masterVolume: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.wave.3")
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { Double(engine.masterVolume) },
                    set: { engine.masterVolume = Float($0) }),
                in: 0...1)
            .frame(width: 110)
        }
        .help("Master volume")
    }

    // MARK: - A–B loop

    private var loopControls: some View {
        HStack(spacing: 6) {
            Button("A") {
                engine.setLoopStart(displayedTime)
            }
            .help("Set loop start at the playhead")

            Button("B") {
                engine.setLoopEnd(displayedTime)
            }
            .help("Set loop end at the playhead (enables the loop)")

            Toggle(isOn: Binding(
                get: { engine.isLoopEnabled },
                set: { engine.isLoopEnabled = $0 })
            ) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .disabled(!engine.hasLoopRegion)
            .help("Repeat the A–B section")

            if engine.loopStart != nil || engine.loopEnd != nil {
                Text(loopRangeLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button {
                    engine.clearLoop()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Clear the loop")
            }
        }
        .font(.caption.bold())
        .controlSize(.small)
    }

    private var loopRangeLabel: String {
        let start = engine.loopStart.map(Self.timeString) ?? "—"
        let end = engine.loopEnd.map(Self.timeString) ?? "—"
        return "\(start)–\(end)"
    }

    // MARK: - Pitch & speed

    private var pitchSpeedButton: some View {
        Button {
            showPitchSpeed.toggle()
        } label: {
            Label(pitchSpeedSummary, systemImage: "dial.medium")
        }
        .controlSize(.small)
        .popover(isPresented: $showPitchSpeed, arrowEdge: .bottom) {
            PitchSpeedControlView()
                .environment(appState)
        }
        .help("Live transpose and playback speed")
    }

    private var pitchSpeedSummary: String {
        let pitchActive = engine.pitchSemitones != 0
        let speedActive = abs(engine.playbackRate - 1) > 0.001
        switch (pitchActive, speedActive) {
        case (false, false):
            return "Pitch & Speed"
        case (true, false):
            return PitchSpeedControlView.pitchLabel(engine.pitchSemitones)
        case (false, true):
            return PitchSpeedControlView.speedLabel(engine.playbackRate)
        case (true, true):
            return "\(PitchSpeedControlView.pitchLabel(engine.pitchSemitones)) · \(PitchSpeedControlView.speedLabel(engine.playbackRate))"
        }
    }

    static func timeString(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
