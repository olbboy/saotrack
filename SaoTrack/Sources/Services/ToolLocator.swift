import Foundation
import Observation

/// Discovers the external tools SaoTrack depends on (ffmpeg, yt-dlp,
/// python+demucs) and can create an app-managed Python virtualenv with
/// demucs installed.
@MainActor
@Observable
final class ToolLocator {

    // MARK: - Well-known locations

    nonisolated static let searchDirectories: [String] = [
        managedVenvBinDirectory.path,
        "/opt/homebrew/bin",
        "/usr/local/bin",
        (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin"),
        "/usr/bin",
    ]

    nonisolated static var appSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SaoTrack", isDirectory: true)
    }

    nonisolated static var managedVenvDirectory: URL {
        appSupportDirectory.appendingPathComponent("venv", isDirectory: true)
    }

    nonisolated static var managedVenvBinDirectory: URL {
        managedVenvDirectory.appendingPathComponent("bin", isDirectory: true)
    }

    /// Torch model cache kept app-local so "model already downloaded" is
    /// detectable and uninstalling is a single folder delete.
    nonisolated static var torchHomeDirectory: URL {
        appSupportDirectory.appendingPathComponent("torch", isDirectory: true)
    }

    nonisolated static var sessionsDirectory: URL {
        appSupportDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    nonisolated static var downloadsDirectory: URL {
        appSupportDirectory.appendingPathComponent("downloads", isDirectory: true)
    }

    // MARK: - State

    private(set) var toolSet = ToolSet()
    private(set) var statuses: [ToolStatus] = [
        ToolStatus(
            id: "ffmpeg",
            displayName: "ffmpeg",
            purpose: "Extracts audio from MKV/WEBM video and encodes MP3 320 kbps.",
            installCommand: "brew install ffmpeg"),
        ToolStatus(
            id: "yt-dlp",
            displayName: "yt-dlp",
            purpose: "Downloads audio from YouTube links.",
            installCommand: "brew install yt-dlp"),
        ToolStatus(
            id: "demucs",
            displayName: "Demucs (Python)",
            purpose: "AI model that separates a song into stems.",
            installCommand: "pipx install demucs"),
    ]
    private(set) var isRefreshing = false
    private(set) var isCreatingVenv = false
    private(set) var venvLog: [String] = []
    private(set) var venvError: String?

    var allToolsReady: Bool {
        toolSet.hasFFmpeg && toolSet.hasYtDlp && toolSet.hasDemucs
    }

    // MARK: - Discovery

    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Coalesces concurrent callers: a refresh triggered while one is
    /// already running awaits the in-flight result instead of returning
    /// early with stale/empty state.
    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let ffmpeg = Self.findExecutable(named: "ffmpeg")
        let ytDlp = Self.findExecutable(named: "yt-dlp")

        var ffmpegVersion = ""
        if let ffmpeg {
            ffmpegVersion = await Self.captureVersion(ffmpeg, ["-version"]) ?? ""
        }
        var ytDlpVersion = ""
        if let ytDlp {
            ytDlpVersion = await Self.captureVersion(ytDlp, ["--version"]) ?? ""
        }

        let demucs = await Self.findDemucsPython()

        toolSet = ToolSet(ffmpeg: ffmpeg, ytDlp: ytDlp, demucsPython: demucs?.python)

        setAvailability("ffmpeg", ffmpeg.map { .found(path: $0.path, version: ffmpegVersion) } ?? .missing)
        setAvailability("yt-dlp", ytDlp.map { .found(path: $0.path, version: ytDlpVersion) } ?? .missing)
        setAvailability("demucs", demucs.map { .found(path: $0.python.path, version: $0.version) } ?? .missing)
    }

    private func setAvailability(_ id: String, _ availability: ToolAvailability) {
        if let index = statuses.firstIndex(where: { $0.id == id }) {
            statuses[index].availability = availability
        }
    }

    nonisolated static func findExecutable(named name: String) -> URL? {
        let fileManager = FileManager.default
        for directory in searchDirectories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Finds a python interpreter that can `import demucs`. The interpreter
    /// URL is stored (not the `demucs` console script) and separation runs
    /// `python -m demucs.separate`, which survives moved/broken shebangs.
    nonisolated static func findDemucsPython() async -> (python: URL, version: String)? {
        var candidates: [URL] = []
        let venvPython = managedVenvBinDirectory.appendingPathComponent("python3")
        if FileManager.default.isExecutableFile(atPath: venvPython.path) {
            candidates.append(venvPython)
        }
        // A pipx-installed demucs script points at its venv's python via shebang.
        for directory in searchDirectories {
            let script = (directory as NSString).appendingPathComponent("demucs")
            if let python = pythonFromShebang(scriptPath: script) {
                candidates.append(python)
            }
        }
        for directory in searchDirectories {
            let python = (directory as NSString).appendingPathComponent("python3")
            if FileManager.default.isExecutableFile(atPath: python) {
                candidates.append(URL(fileURLWithPath: python))
            }
        }

        var seen = Set<String>()
        for python in candidates where seen.insert(python.path).inserted {
            if let result = try? await ProcessRunner.run(
                python, ["-c", "import demucs; print(demucs.__version__)"]),
                !result.stdout.isEmpty {
                return (python, result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return nil
    }

    private nonisolated static func pythonFromShebang(scriptPath: String) -> URL? {
        guard FileManager.default.isExecutableFile(atPath: scriptPath),
              let handle = FileHandle(forReadingAtPath: scriptPath),
              let data = try? handle.read(upToCount: 512),
              let head = String(data: data, encoding: .utf8),
              head.hasPrefix("#!") else { return nil }
        let firstLine = head.split(separator: "\n", maxSplits: 1)[0]
        let interpreter = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard interpreter.contains("python"),
              FileManager.default.isExecutableFile(atPath: interpreter) else { return nil }
        return URL(fileURLWithPath: interpreter)
    }

    private nonisolated static func captureVersion(_ tool: URL, _ arguments: [String]) async -> String? {
        guard let result = try? await ProcessRunner.run(tool, arguments) else { return nil }
        return result.stdout.split(separator: "\n").first.map(String.init)
    }

    // MARK: - Managed venv

    /// Creates `~/Library/Application Support/SaoTrack/venv` and installs
    /// demucs into it (pulls PyTorch — roughly 2 GB of downloads).
    func createManagedVenv() async {
        guard !isCreatingVenv else { return }
        isCreatingVenv = true
        venvError = nil
        venvLog = ["Creating Python environment…"]
        defer { isCreatingVenv = false }

        do {
            guard let python = Self.findExecutable(named: "python3")
                ?? (FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")
                    ? URL(fileURLWithPath: "/usr/bin/python3") : nil) else {
                throw AppError.toolMissing(
                    tool: "python3",
                    hint: "Install Python 3 first: brew install python or install the Xcode Command Line Tools.")
            }

            try FileManager.default.createDirectory(
                at: Self.appSupportDirectory, withIntermediateDirectories: true)
            try await ProcessRunner.run(python, ["-m", "venv", Self.managedVenvDirectory.path])

            let pip = Self.managedVenvBinDirectory.appendingPathComponent("pip3")
            try await streamToLog(pip, ["install", "--upgrade", "pip"])
            venvLog.append("Installing demucs (downloads PyTorch, ~2 GB — this takes a while)…")
            try await streamToLog(pip, ["install", "demucs"])

            venvLog.append("Done. Verifying…")
            await refresh()
            if !toolSet.hasDemucs {
                venvError = "Environment was created but demucs could not be imported. Check the log above."
            } else {
                venvLog.append("Demucs is ready.")
            }
        } catch {
            venvError = error.localizedDescription
        }
    }

    private func streamToLog(_ tool: URL, _ arguments: [String]) async throws {
        var exitCode: Int32 = -1
        for try await line in ProcessRunner.stream(tool, arguments) {
            switch line {
            case .stdout(let text), .stderr(let text):
                venvLog.append(text)
                if venvLog.count > 400 { venvLog.removeFirst(venvLog.count - 400) }
            case .exit(let code):
                exitCode = code
            }
        }
        guard exitCode == 0 else {
            throw ProcessRunner.RunnerError.nonZeroExit(
                tool: tool.lastPathComponent, code: exitCode,
                stderr: venvLog.suffix(5).joined(separator: "\n"))
        }
    }
}
