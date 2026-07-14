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
    /// Identity of the newest job. Superseded jobs compare their captured
    /// token against this before touching phase/error state, so a stale
    /// job unwinding after cancellation can't clobber the active one.
    private var currentJobToken = UUID()
    private var analysisJob: Task<Void, Never>?
    private var analysisToken = UUID()
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
        guard !phase.isBusy else { return }
        startJob { [self] token in
            setPhase(.importing("Loading \(url.lastPathComponent)…"))
            do {
                let loaded = try await importer.importMedia(from: url, tools: toolLocator.toolSet) { status in
                    Task { @MainActor in
                        if self.isCurrentJob(token), case .importing = self.phase {
                            self.setPhase(.importing(status))
                        }
                    }
                }
                try Task.checkCancellation()
                guard isCurrentJob(token) else { return }
                try applyLoadedMedia(loaded)
            } catch is CancellationError {
                if isCurrentJob(token) { revertToStablePhase() }
            } catch {
                if isCurrentJob(token) { fail(AppError.from(error) { .importFailed($0) }) }
            }
        }
    }

    func downloadFromYouTube(_ urlString: String) {
        guard !phase.isBusy else { return }
        startJob { [self] token in
            setPhase(.downloading(0))
            do {
                let downloaded = try await youtubeService.download(
                    urlString: urlString, tools: toolLocator.toolSet) { fraction in
                    Task { @MainActor in
                        if self.isCurrentJob(token), case .downloading = self.phase {
                            self.setPhase(.downloading(fraction))
                        }
                    }
                }
                try Task.checkCancellation()
                guard isCurrentJob(token) else { return }
                setPhase(.importing("Loading \(downloaded.lastPathComponent)…"))
                let loaded = try await importer.importMedia(from: downloaded, tools: toolLocator.toolSet) { _ in }
                try Task.checkCancellation()
                guard isCurrentJob(token) else { return }
                try applyLoadedMedia(loaded)
            } catch is CancellationError {
                if isCurrentJob(token) { revertToStablePhase() }
            } catch {
                if isCurrentJob(token) { fail(AppError.from(error) { .downloadFailed($0) }) }
            }
        }
    }

    private func applyLoadedMedia(_ loaded: LoadedMedia) throws {
        playerEngine.stop()
        analysis = nil
        analysisJob?.cancel()
        analysisToken = UUID()
        isAnalyzing = false
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
        guard let media, !phase.isBusy, !mixer.isSeparated else { return }
        startJob { [self] token in
            playerEngine.pause()
            setPhase(.separating(StemSeparationService.Progress(stage: .separating(0))))
            do {
                let stems = try await separationService.separate(
                    input: media.playableWavURL,
                    sessionDirectory: media.sessionDirectory,
                    tools: toolLocator.toolSet,
                    useGPU: useGPUForSeparation) { progressUpdate in
                    Task { @MainActor in
                        if self.isCurrentJob(token), case .separating = self.phase {
                            self.setPhase(.separating(progressUpdate))
                        }
                    }
                }
                try Task.checkCancellation()
                guard isCurrentJob(token) else { return }
                let stemTracks = StemKind.allCases.compactMap { kind in
                    stems[kind].map { StemTrack(kind: kind, name: kind.displayName, url: $0) }
                }
                try playerEngine.load(tracks: stemTracks)
                mixer.setTracks(stemTracks)
                setPhase(.separated)
            } catch is CancellationError {
                if isCurrentJob(token) { revertToStablePhase() }
            } catch {
                if isCurrentJob(token) { fail(AppError.from(error) { .separationFailed($0) }) }
            }
        }
    }

    // MARK: - Analysis

    func detectKeyAndBPM() {
        guard let media, !isAnalyzing else { return }
        analysisJob?.cancel()
        let token = UUID()
        analysisToken = token
        isAnalyzing = true
        analysisJob = Task { [self] in
            do {
                let result = try await analysisService.analyze(fileURL: media.playableWavURL)
                if analysisToken == token { analysis = result }
            } catch is CancellationError {
                // superseded by a new file — ignore
            } catch {
                if analysisToken == token {
                    presentedError = AppError.from(error) { .analysisFailed($0) }
                }
            }
            if analysisToken == token { isAnalyzing = false }
        }
    }

    // MARK: - Export

    func exportMix() {
        guard media != nil, !phase.isBusy else { return }
        let format = exportFormat
        let panel = NSSavePanel()
        panel.title = "Export Mix"
        panel.nameFieldStringValue = "\(media?.title ?? "mix") (Mix).\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let inputs = mixer.mixInputs()
        let masterVolume = playerEngine.masterVolume
        startJob { [self] token in
            setPhase(.exporting("Exporting mix…", 0))
            do {
                try await exportService.exportMix(
                    inputs: inputs,
                    masterVolume: masterVolume,
                    format: format,
                    to: destination,
                    tools: toolLocator.toolSet) { fraction in
                    Task { @MainActor in
                        if self.isCurrentJob(token), case .exporting = self.phase {
                            self.setPhase(.exporting("Exporting mix…", fraction))
                        }
                    }
                }
                guard isCurrentJob(token) else { return }
                revertToStablePhase()
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch is CancellationError {
                if isCurrentJob(token) { revertToStablePhase() }
            } catch {
                if isCurrentJob(token) { fail(AppError.from(error) { .exportFailed($0) }) }
            }
        }
    }

    func exportAllStems() {
        guard mixer.isSeparated, !phase.isBusy else { return }
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
        startJob { [self] token in
            setPhase(.exporting("Exporting stems…", 0))
            do {
                try await exportService.exportAllStems(
                    stems: stems, format: format, to: directory,
                    tools: toolLocator.toolSet) { fraction in
                    Task { @MainActor in
                        if self.isCurrentJob(token), case .exporting = self.phase {
                            self.setPhase(.exporting("Exporting stems…", fraction))
                        }
                    }
                }
                guard isCurrentJob(token) else { return }
                revertToStablePhase()
                NSWorkspace.shared.activateFileViewerSelecting([directory])
            } catch is CancellationError {
                if isCurrentJob(token) { revertToStablePhase() }
            } catch {
                if isCurrentJob(token) { fail(AppError.from(error) { .exportFailed($0) }) }
            }
        }
    }

    func exportSingleStem(_ track: StemTrack) {
        guard !phase.isBusy else { return }
        let format = exportFormat
        let panel = NSSavePanel()
        panel.title = "Export \(track.name)"
        panel.nameFieldStringValue = "\(track.kind?.rawValue ?? track.name).\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        startJob { [self] token in
            setPhase(.exporting("Exporting \(track.name)…", 0))
            do {
                try await exportService.exportStem(
                    url: track.url, format: format, to: destination, tools: toolLocator.toolSet)
                guard isCurrentJob(token) else { return }
                revertToStablePhase()
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch is CancellationError {
                if isCurrentJob(token) { revertToStablePhase() }
            } catch {
                if isCurrentJob(token) { fail(AppError.from(error) { .exportFailed($0) }) }
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

    /// Starts a new exclusive job. The closure receives a token identifying
    /// this job; every phase/error mutation after an await must be guarded
    /// with `isCurrentJob(token)`.
    private func startJob(_ operation: @escaping @MainActor (_ token: UUID) async -> Void) {
        currentJob?.cancel()
        let token = UUID()
        currentJobToken = token
        currentJob = Task { await operation(token) }
    }

    private func isCurrentJob(_ token: UUID) -> Bool {
        currentJobToken == token
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
