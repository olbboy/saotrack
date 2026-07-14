import Foundation

/// Runs Demucs (`htdemucs_6s`) as a Python subprocess and post-processes the
/// six model outputs into the app's five stems: the guitar stem is summed
/// into "other".
actor StemSeparationService {

    static let modelName = "htdemucs_6s"

    struct Progress: Sendable, Equatable {
        enum Stage: Sendable, Equatable {
            /// First run: torch is downloading the model checkpoint (~300 MB).
            case preparingModel
            case separating(Double) // 0...1
            case merging
        }
        let stage: Stage

        var label: String {
            switch stage {
            case .preparingModel:
                return "Downloading separation model (first run, ~300 MB)…"
            case .separating:
                return "Separating stems… this can take a few minutes"
            case .merging:
                return "Finishing stems…"
            }
        }

        var fraction: Double? {
            if case .separating(let value) = stage { return value }
            return nil
        }
    }

    private static let tqdmPattern = try! NSRegularExpression(pattern: #"(?:^|\s)([\d.]+)%\|"#)

    /// Separates `input` and returns one WAV per stem kind.
    func separate(
        input: URL,
        sessionDirectory: URL,
        tools: ToolSet,
        useGPU: Bool,
        progress: @Sendable @escaping (Progress) -> Void
    ) async throws -> [StemKind: URL] {
        guard let python = tools.demucsPython else {
            throw AppError.toolMissing(
                tool: "Demucs",
                hint: "Install it with: pipx install demucs — or create the managed Python environment in Setup.")
        }

        let outputRoot = sessionDirectory.appendingPathComponent("demucs", isDirectory: true)
        try? FileManager.default.removeItem(at: outputRoot)
        try FileManager.default.createDirectory(at: ToolLocator.torchHomeDirectory,
                                                withIntermediateDirectories: true)

        let arguments = [
            "-m", "demucs.separate",
            "-n", Self.modelName,
            "-d", useGPU ? "mps" : "cpu",
            "-o", outputRoot.path,
            input.path,
        ]
        var environment = ProcessRunner.environment(extra: [
            "PYTHONUNBUFFERED": "1",
            "TORCH_HOME": ToolLocator.torchHomeDirectory.path,
        ])
        if let ffmpeg = tools.ffmpeg {
            environment["PATH"] = ffmpeg.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "")
        }

        progress(Progress(stage: .separating(0)))

        var maxFraction = 0.0
        var stderrTail: [String] = []
        var exitCode: Int32 = -1

        do {
            for try await line in ProcessRunner.stream(python, arguments, environment: environment) {
                switch line {
                case .stdout(let text), .stderr(let text):
                    if text.contains("Downloading") || text.contains("download.pytorch.org") {
                        progress(Progress(stage: .preparingModel))
                    } else if let fraction = Self.parseTqdm(text) {
                        // tqdm restarts between shifts/segments; keep monotonic.
                        maxFraction = max(maxFraction, fraction)
                        progress(Progress(stage: .separating(maxFraction)))
                    } else {
                        stderrTail.append(text)
                        if stderrTail.count > 12 { stderrTail.removeFirst() }
                    }
                case .exit(let code):
                    exitCode = code
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: outputRoot)
            throw error
        }

        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: outputRoot)
            throw CancellationError()
        }
        guard exitCode == 0 else {
            try? FileManager.default.removeItem(at: outputRoot)
            throw AppError.separationFailed(stderrTail.suffix(5).joined(separator: "\n"))
        }

        progress(Progress(stage: .merging))
        return try mergeOutputs(input: input, outputRoot: outputRoot, sessionDirectory: sessionDirectory)
    }

    private static func parseTqdm(_ line: String) -> Double? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = tqdmPattern.firstMatch(in: line, range: range),
              let percentRange = Range(match.range(at: 1), in: line),
              let percent = Double(line[percentRange]) else { return nil }
        return min(1.0, percent / 100.0)
    }

    /// demucs writes `<root>/htdemucs_6s/<track>/{vocals,drums,bass,guitar,piano,other}.wav`.
    /// Moves the five app stems into `<session>/stems/` with guitar+other summed.
    private func mergeOutputs(
        input: URL,
        outputRoot: URL,
        sessionDirectory: URL
    ) throws -> [StemKind: URL] {
        let trackName = input.deletingPathExtension().lastPathComponent
        var modelDirectory = outputRoot
            .appendingPathComponent(Self.modelName, isDirectory: true)
            .appendingPathComponent(trackName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: modelDirectory.path) {
            // Defensive: locate the single track folder demucs actually created.
            let modelRoot = outputRoot.appendingPathComponent(Self.modelName, isDirectory: true)
            let children = (try? FileManager.default.contentsOfDirectory(
                at: modelRoot, includingPropertiesForKeys: nil)) ?? []
            guard let found = children.first(where: { $0.hasDirectoryPath }) else {
                throw AppError.separationFailed("Demucs finished but produced no output folder.")
            }
            modelDirectory = found
        }

        let stemsDirectory = sessionDirectory.appendingPathComponent("stems", isDirectory: true)
        try? FileManager.default.removeItem(at: stemsDirectory)
        try FileManager.default.createDirectory(at: stemsDirectory, withIntermediateDirectories: true)

        func modelStem(_ name: String) -> URL {
            modelDirectory.appendingPathComponent("\(name).wav")
        }

        var stems: [StemKind: URL] = [:]
        for kind in StemKind.allCases {
            let destination = stemsDirectory.appendingPathComponent("\(kind.rawValue).wav")
            if kind == .other {
                let guitar = modelStem("guitar")
                let other = modelStem("other")
                if FileManager.default.fileExists(atPath: guitar.path),
                   FileManager.default.fileExists(atPath: other.path) {
                    try AudioFileHelpers.sumWavFiles(guitar, other, output: destination)
                } else if FileManager.default.fileExists(atPath: other.path) {
                    try FileManager.default.moveItem(at: other, to: destination)
                } else {
                    throw AppError.separationFailed("The \"other\" stem is missing from the Demucs output.")
                }
            } else {
                let source = modelStem(kind.rawValue)
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw AppError.separationFailed("The \"\(kind.rawValue)\" stem is missing from the Demucs output.")
                }
                try FileManager.default.moveItem(at: source, to: destination)
            }
            stems[kind] = destination
        }

        try? FileManager.default.removeItem(at: outputRoot)
        return stems
    }
}
