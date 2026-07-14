import AppKit
import CoreAudio
import Foundation
import Observation

/// Central orchestrator: owns the phase state machine, the loaded media,
/// the playback engine, and every long-running job (import, download,
/// separation, export, analysis). Exactly one long job runs at a time.
@MainActor
@Observable
final class AppState {

    enum Phase: Equatable {
        case empty
        case importing(String)
        case downloading(Double)
        case loaded
        case separating(StemSeparationService.Progress)
        case separated
        case exporting(String, Double)

        var isBusy: Bool {
            switch self {
            case .empty, .loaded, .separated: return false
            case .importing, .downloading, .separating, .exporting: return true
            }
        }
    }

    // MARK: - State

    private(set) var phase: Phase = .empty
    private(set) var media: LoadedMedia?
    private(set) var analysis: MusicalAnalysis?
    private(set) var isAnalyzing = false
    var presentedError: AppError?

    var autoSeparate: Bool = UserDefaults.standard.bool(forKey: "autoSeparate") {
        didSet { UserDefaults.standard.set(autoSeparate, forKey: "autoSeparate") }
    }
    var useGPUForSeparation: Bool = UserDefaults.standard.bool(forKey: "useGPUForSeparation") {
        didSet { UserDefaults.standard.set(useGPUForSeparation, forKey: "useGPUForSeparation") }
    }
    var exportFormat: ExportFormat = .wav16
    var selectedOutputDeviceID: AudioDeviceID?

    let toolLocator = ToolLocator()
    let playerEngine = AudioPlayerEngine()
    let deviceManager = AudioDeviceManager()
    let mixer = MixerViewModel()

    private let importer = MediaImporter()
    private let youtubeService = YouTubeService()
    private let separationService = StemSeparationService()
    private let exportService = ExportService()
    private let analysisService = AnalysisService()

    private var currentJob: Task<Void, Never>?
    private var analysisJob: Task<Void, Never>?
    private var lastStablePhase: Phase = .empty

    init() {
        mixer.attach(engine: playerEngine)
        selectedOutputDeviceID = AudioDeviceManager.defaultOutputDeviceID()
        cleanUpWorkingDirectories()
        Task { await toolLocator.refresh() }
    }

    // MARK: - Loading

    /// Toolbar "Open File" — shows the picker, then imports.
    func loadAnotherFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose an audio or video file"
        panel.allowedContentTypes = MediaImporter.supportedContentTypes
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadFile(url)
    }

    func loadFile(_ url: URL) {
        startJob { [self] in
            setPhase(.importing("Loading \(url.lastPathComponent)…"))
            do {
                let loaded = try await importer.importMedia(from: url, tools: toolLocator.toolSet) { status in
                    Task { @MainActor in
                        if case .importing = self.phase { self.setPhase(.importing(status)) }
                    }
                }
                try applyLoadedMedia(loaded)
            } catch is CancellationError {
                revertToStablePhase()
            } catch {
                fail(AppError.from(error) { .importFailed($0) })
            }
        }
    }

    func downloadFromYouTube(_ urlString: String) {
        startJob { [self] in
            setPhase(.downloading(0))
            do {
                let downloaded = try await youtubeService.download(
                    urlString: urlString, tools: toolLocator.toolSet) { fraction in
                    Task { @MainActor in
                        if case .downloading = self.phase { self.setPhase(.downloading(fraction)) }
                    }
                }
                setPhase(.importing("Loading \(downloaded.lastPathComponent)…"))
                let loaded = try await importer.importMedia(from: downloaded, tools: toolLocator.toolSet) { _ in }
                try applyLoadedMedia(loaded)
            } catch is CancellationError {
                revertToStablePhase()
            } catch {
                fail(AppError.from(error) { .downloadFailed($0) })
            }
        }
    }

    private func applyLoadedMedia(_ loaded: LoadedMedia) throws {
        playerEngine.stop()
        analysis = nil
        analysisJob?.cancel()
        media = loaded

        let originalTrack = StemTrack.original(url: loaded.playableWavURL, title: loaded.title)
        try playerEngine.load(tracks: [originalTrack])
        mixer.setTracks([originalTrack])
        setPhase(.loaded)

        if autoSeparate {
            separateStems()
        }
    }

    // MARK: - Separation

    func separateStems() {
        guard let media else { return }
        guard !phase.isBusy || currentJobIsFinishing() else { return }
        startJob { [self] in
            playerEngine.pause()
            setPhase(.separating(StemSeparationService.Progress(stage: .separating(0))))
            do {
                let stems = try await separationService.separate(
                    input: media.playableWavURL,
                    sessionDirectory: media.sessionDirectory,
                    tools: toolLocator.toolSet,
                    useGPU: useGPUForSeparation) { progressUpdate in
                    Task { @MainActor in
                        if case .separating = self.phase { self.setPhase(.separating(progressUpdate)) }
                    }
                }
                let stemTracks = StemKind.allCases.compactMap { kind in
                    stems[kind].map { StemTrack(kind: kind, name: kind.displayName, url: $0) }
                }
                try playerEngine.load(tracks: stemTracks)
                mixer.setTracks(stemTracks)
                setPhase(.separated)
            } catch is CancellationError {
                revertToStablePhase()
            } catch {
                fail(AppError.from(error) { .separationFailed($0) })
            }
        }
    }

    // MARK: - Analysis

    func detectKeyAndBPM() {
        guard let media, !isAnalyzing else { return }
        analysisJob?.cancel()
        isAnalyzing = true
        analysisJob = Task { [self] in
            do {
                let result = try await analysisService.analyze(fileURL: media.playableWavURL)
                analysis = result
            } catch is CancellationError {
                // superseded by a new file — ignore
            } catch {
                presentedError = AppError.from(error) { .analysisFailed($0) }
            }
            isAnalyzing = false
        }
    }

    // MARK: - Export

    func exportMix() {
        guard media != nil else { return }
        let format = exportFormat
        let panel = NSSavePanel()
        panel.title = "Export Mix"
        panel.nameFieldStringValue = "\(media?.title ?? "mix") (Mix).\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let inputs = mixer.mixInputs()
        let masterVolume = playerEngine.masterVolume
        startJob { [self] in
            setPhase(.exporting("Exporting mix…", 0))
            do {
                try await exportService.exportMix(
                    inputs: inputs,
                    masterVolume: masterVolume,
                    format: format,
                    to: destination,
                    tools: toolLocator.toolSet) { fraction in
                    Task { @MainActor in
                        if case .exporting = self.phase {
                            self.setPhase(.exporting("Exporting mix…", fraction))
                        }
                    }
                }
                revertToStablePhase()
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch is CancellationError {
                revertToStablePhase()
            } catch {
                fail(AppError.from(error) { .exportFailed($0) })
            }
        }
    }

    func exportAllStems() {
        guard mixer.isSeparated else { return }
        let format = exportFormat
        let panel = NSOpenPanel()
        panel.title = "Export All Stems"
        panel.message = "Choose a folder for the stem files"
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        let stems: [(kind: StemKind, url: URL)] = mixer.tracks.compactMap { track in
            track.kind.map { (kind: $0, url: track.url) }
        }
        startJob { [self] in
            setPhase(.exporting("Exporting stems…", 0))
            do {
                try await exportService.exportAllStems(
                    stems: stems, format: format, to: directory,
                    tools: toolLocator.toolSet) { fraction in
                    Task { @MainActor in
                        if case .exporting = self.phase {
                            self.setPhase(.exporting("Exporting stems…", fraction))
                        }
                    }
                }
                revertToStablePhase()
                NSWorkspace.shared.activateFileViewerSelecting([directory])
            } catch is CancellationError {
                revertToStablePhase()
            } catch {
                fail(AppError.from(error) { .exportFailed($0) })
            }
        }
    }

    func exportSingleStem(_ track: StemTrack) {
        let format = exportFormat
        let panel = NSSavePanel()
        panel.title = "Export \(track.name)"
        panel.nameFieldStringValue = "\(track.kind?.rawValue ?? track.name).\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        startJob { [self] in
            setPhase(.exporting("Exporting \(track.name)…", 0))
            do {
                try await exportService.exportStem(
                    url: track.url, format: format, to: destination, tools: toolLocator.toolSet)
                revertToStablePhase()
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch is CancellationError {
                revertToStablePhase()
            } catch {
                fail(AppError.from(error) { .exportFailed($0) })
            }
        }
    }

    // MARK: - Output device

    func selectOutputDevice(_ deviceID: AudioDeviceID) {
        selectedOutputDeviceID = deviceID
        do {
            try playerEngine.setOutputDevice(deviceID)
        } catch {
            presentedError = AppError.from(error) { .playbackFailed($0) }
        }
    }

    // MARK: - Job plumbing

    func cancelCurrentJob() {
        currentJob?.cancel()
    }

    private func startJob(_ operation: @escaping @MainActor () async -> Void) {
        currentJob?.cancel()
        currentJob = Task { await operation() }
    }

    private func currentJobIsFinishing() -> Bool {
        currentJob?.isCancelled ?? true
    }

    private func setPhase(_ newPhase: Phase) {
        phase = newPhase
        if !newPhase.isBusy {
            lastStablePhase = newPhase
        }
    }

    private func revertToStablePhase() {
        setPhase(lastStablePhase)
    }

    private func fail(_ error: AppError) {
        presentedError = error
        revertToStablePhase()
    }

    private func cleanUpWorkingDirectories() {
        let directories = [ToolLocator.sessionsDirectory, ToolLocator.downloadsDirectory]
        Task.detached(priority: .background) {
            let fileManager = FileManager.default
            for directory in directories {
                let children = (try? fileManager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)) ?? []
                for child in children {
                    try? fileManager.removeItem(at: child)
                }
            }
        }
    }
}
