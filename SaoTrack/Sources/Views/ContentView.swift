import SwiftUI

@MainActor
struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var showSetup = false
    @State private var showYouTube = false
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var appState = appState

        ZStack {
            if appState.media == nil {
                emptyStateView
            } else {
                loadedView
            }

            if appState.phase.isBusy {
                ProgressOverlayView()
            }
        }
        // Whole-window drop target so a new file can be dropped even after
        // one is loaded (the empty state's DropZone remains as the visual cue).
        .dropDestination(for: URL.self) { urls, _ in
            guard !appState.phase.isBusy,
                  let url = urls.first(where: { MediaImporter.isSupported($0) }) else {
                return false
            }
            appState.loadFile(url)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted, appState.media != nil {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showSetup) {
            SetupView()
                .environment(appState)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { appState.presentedError != nil },
                set: { if !$0 { appState.presentedError = nil } })
        ) {
            Button("OK", role: .cancel) {}
            if case .toolMissing? = appState.presentedError {
                Button("Open Setup") { showSetup = true }
            }
        } message: {
            Text(appState.presentedError?.errorDescription ?? "")
        }
        .task {
            await appState.toolLocator.refresh()
            if !appState.toolLocator.allToolsReady {
                showSetup = true
            }
        }
    }

    // MARK: - Empty state

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("SaoTrack")
                .font(.system(size: 34, weight: .bold))
            Text("Stem Splitter & Multi-Track Mixer")
                .font(.title3)
                .foregroundStyle(.secondary)
            DropZoneView()
                .frame(maxWidth: 560)
            YouTubeBarView()
                .frame(maxWidth: 560)
            Spacer()
        }
        .padding(32)
    }

    // MARK: - Loaded state

    private var loadedView: some View {
        VStack(spacing: 16) {
            TransportBarView()
            AnalysisPanelView()
            MixerView()
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            if appState.media != nil {
                Button {
                    appState.loadAnotherFile()
                } label: {
                    Label("Open File", systemImage: "folder")
                }
                .help("Load another audio or video file")

                Button {
                    showYouTube.toggle()
                } label: {
                    Label("YouTube", systemImage: "link")
                }
                .popover(isPresented: $showYouTube, arrowEdge: .bottom) {
                    YouTubeBarView()
                        .environment(appState)
                        .padding(16)
                        .frame(width: 420)
                }
                .help("Download & load another song from a YouTube link")

                ExportMenuView()
            }

            outputDevicePicker

            Button {
                showSetup = true
            } label: {
                Label("Setup", systemImage: "gearshape")
            }
            .help("External tools (ffmpeg, yt-dlp, Demucs)")
        }
    }

    private var outputDevicePicker: some View {
        Picker(selection: Binding(
            get: { appState.selectedOutputDeviceID },
            set: { newValue in
                if let newValue { appState.selectOutputDevice(newValue) }
            }
        )) {
            ForEach(appState.deviceManager.outputDevices) { device in
                Text(device.name).tag(Optional(device.id))
            }
        } label: {
            Label("Output Device", systemImage: "speaker.wave.2")
        }
        .help("Choose the audio output device")
    }
}
