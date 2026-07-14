import SwiftUI

@main
@MainActor
struct SaoTrackApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 860, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        .commands {
            fileCommands
            trackCommands
            playbackCommands
        }

        Settings {
            SetupView()
                .environment(appState)
        }
    }

    // MARK: - Menu commands

    @CommandsBuilder
    private var fileCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") {
                appState.loadAnotherFile()
            }
            .keyboardShortcut("o")
            .disabled(appState.phase.isBusy)

            Menu("Open Recent") {
                ForEach(appState.recentFiles, id: \.self) { url in
                    Button(url.lastPathComponent) {
                        appState.loadFile(url)
                    }
                }
                if appState.recentFiles.isEmpty {
                    Text("No Recent Files")
                } else {
                    Divider()
                    Button("Clear Menu") {
                        appState.clearRecentFiles()
                    }
                }
            }
            .disabled(appState.phase.isBusy)

            Divider()

            Button("Export Mix…") {
                appState.exportMix()
            }
            .keyboardShortcut("e")
            .disabled(appState.media == nil || appState.phase.isBusy)

            Button("Export All Stems…") {
                appState.exportAllStems()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!appState.mixer.isSeparated || appState.phase.isBusy)
        }
    }

    @CommandsBuilder
    private var trackCommands: some Commands {
        CommandMenu("Track") {
            Button("Separate Tracks") {
                appState.separateStems()
            }
            .keyboardShortcut("d")
            .disabled(appState.media == nil || appState.phase.isBusy || appState.mixer.isSeparated)

            Button("Detect Key & BPM") {
                appState.detectKeyAndBPM()
            }
            .keyboardShortcut("k")
            .disabled(appState.media == nil || appState.isAnalyzing)

            Divider()

            Button("Karaoke Preset (Mute Vocals)") {
                appState.mixer.applyKaraokePreset()
            }
            .disabled(!appState.mixer.isSeparated)

            Button("Acapella Preset (Solo Vocals)") {
                appState.mixer.applyAcapellaPreset()
            }
            .disabled(!appState.mixer.isSeparated)

            Button("Reset Mixer") {
                appState.mixer.resetMix()
            }
            .disabled(appState.media == nil)
        }
    }

    @CommandsBuilder
    private var playbackCommands: some Commands {
        CommandMenu("Playback") {
            Button(appState.playerEngine.state == .playing ? "Pause" : "Play") {
                let engine = appState.playerEngine
                engine.state == .playing ? engine.pause() : engine.play()
            }
            .keyboardShortcut("p")
            .disabled(appState.media == nil)

            Button("Stop") {
                appState.playerEngine.stop()
            }
            .keyboardShortcut(".")
            .disabled(appState.media == nil)

            Button("Skip Back 5 Seconds") {
                appState.playerEngine.skip(by: -5)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            .disabled(appState.media == nil)

            Button("Skip Forward 5 Seconds") {
                appState.playerEngine.skip(by: 5)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            .disabled(appState.media == nil)

            Divider()

            Button("Set Loop Start") {
                appState.playerEngine.setLoopStart(appState.playerEngine.currentTime)
            }
            .keyboardShortcut("[")
            .disabled(appState.media == nil)

            Button("Set Loop End") {
                appState.playerEngine.setLoopEnd(appState.playerEngine.currentTime)
            }
            .keyboardShortcut("]")
            .disabled(appState.media == nil)

            Button(appState.playerEngine.isLoopEnabled ? "Disable Loop" : "Enable Loop") {
                appState.playerEngine.isLoopEnabled.toggle()
            }
            .keyboardShortcut("l")
            .disabled(!appState.playerEngine.hasLoopRegion)

            Button("Clear Loop") {
                appState.playerEngine.clearLoop()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(appState.playerEngine.loopStart == nil && appState.playerEngine.loopEnd == nil)
        }
    }
}
