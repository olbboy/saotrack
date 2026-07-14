import SwiftUI

struct YouTubeBarView: View {
    @Environment(AppState.self) private var appState
    @State private var urlString = ""

    private var ytDlpAvailable: Bool { appState.toolLocator.toolSet.hasYtDlp }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("YouTube URL...", text: $urlString)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(download)

                Button("Download & Load", action: download)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ytDlpAvailable || urlString.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !ytDlpAvailable {
                Text("yt-dlp is not installed — open Setup to enable YouTube downloads.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Only download content you own or have the rights to use.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func download() {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard ytDlpAvailable, !trimmed.isEmpty else { return }
        appState.downloadFromYouTube(trimmed)
    }
}
