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

    private func resultBox(title: String, value: String?) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Group {
                if let value {
                    Text(value)
                        .font(.title3.weight(.bold).monospacedDigit())
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
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
    }
}
