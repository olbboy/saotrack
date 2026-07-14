import SwiftUI

/// Modal-style overlay shown while a long job (import, download,
/// separation, export) runs, with a Cancel button.
@MainActor
struct ProgressOverlayView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                if let fraction {
                    ProgressView(value: fraction)
                        .frame(width: 280)
                    Text("\(Int(fraction * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .frame(width: 280)
                }

                if case .separating = appState.phase {
                    Text("Do not quit the app while separation is running.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Cancel") {
                    appState.cancelCurrentJob()
                }
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 24)
        }
    }

    private var title: String {
        switch appState.phase {
        case .importing(let status): return status
        case .downloading: return "Downloading from YouTube…"
        case .separating(let progress): return progress.label
        case .exporting(let label, _): return label
        case .empty, .loaded, .separated: return ""
        }
    }

    private var fraction: Double? {
        switch appState.phase {
        case .downloading(let value): return value
        case .separating(let progress): return progress.fraction
        case .exporting(_, let value): return value
        case .importing, .empty, .loaded, .separated: return nil
        }
    }
}
