import SwiftUI

/// "Musical Analysis" — the KEY and BPM result boxes.
@MainActor
struct AnalysisPanelView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 16) {
            Text("Musical Analysis")
                .font(.headline)

            resultBox(title: "KEY", value: appState.analysis?.keyName)
            resultBox(title: "BPM", value: appState.analysis?.bpmDisplay)

            // Live transpose applied → show the key the user is hearing.
            if let shiftedKey = transposedKeyName {
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                resultBox(title: playingInTitle, value: shiftedKey, accent: true)
            }

            if let confidence = appState.analysis?.keyConfidence, confidence > 0 {
                Text(String(format: "key margin %.2f", confidence))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

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
            .disabled(appState.isAnalyzing || appState.media == nil)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Key the song currently sounds in, when a transpose is active.
    private var transposedKeyName: String? {
        let semitones = Int(appState.playerEngine.pitchSemitones)
        guard semitones != 0, let analysis = appState.analysis else { return nil }
        return analysis.transposedKeyName(by: semitones)
    }

    private var playingInTitle: String {
        let semitones = Int(appState.playerEngine.pitchSemitones)
        return semitones > 0 ? "PLAYING IN (+\(semitones))" : "PLAYING IN (\(semitones))"
    }

    private func resultBox(title: String, value: String?, accent: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(accent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            Group {
                if let value {
                    Text(value)
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(accent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                } else if appState.isAnalyzing {
                    ProgressView().controlSize(.small)
                } else {
                    Text("—")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minHeight: 24)
        }
        .frame(minWidth: 92)
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(accent ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.25)))
    }
}
