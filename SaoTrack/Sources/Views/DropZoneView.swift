import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @Environment(AppState.self) private var appState
    @State private var isTargeted = false
    @State private var showFileImporter = false

    var body: some View {
        Button {
            showFileImporter = true
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 36))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                Text("Drop an audio or video file here")
                    .font(.headline)
                Text("Click to choose a file")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("MP3 · WAV · M4A · AAC · FLAC · MP4 · MOV · MKV · WEBM")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 44)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                        style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { MediaImporter.isSupported($0) }) else {
                return false
            }
            appState.loadFile(url)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: MediaImporter.supportedContentTypes
        ) { result in
            if case .success(let url) = result {
                // Not sandboxed, but harmless if the URL is security-scoped.
                _ = url.startAccessingSecurityScopedResource()
                appState.loadFile(url)
            }
        }
    }
}
