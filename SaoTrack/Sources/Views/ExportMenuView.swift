import SwiftUI

/// Toolbar menu: format choice + "Export Mix" / "Export All Stems".
struct ExportMenuView: View {
    @Environment(AppState.self) private var appState

    private var ffmpegAvailable: Bool { appState.toolLocator.toolSet.hasFFmpeg }

    var body: some View {
        @Bindable var appState = appState

        Menu {
            Picker("Format", selection: $appState.exportFormat) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.rawValue)
                        .tag(format)
                }
            }
            .pickerStyle(.inline)

            if !ffmpegAvailable {
                Text("MP3 export requires ffmpeg (see Setup)")
            }

            Divider()

            Button("Export Mix") {
                appState.exportMix()
            }
            .disabled(exportDisabled)

            Button("Export All Stems") {
                appState.exportAllStems()
            }
            .disabled(exportDisabled || !appState.mixer.isSeparated)
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .help("Export the current mix or all stems")
    }

    private var exportDisabled: Bool {
        appState.media == nil
            || appState.phase.isBusy
            || (appState.exportFormat.requiresFFmpeg && !ffmpegAvailable)
    }
}
