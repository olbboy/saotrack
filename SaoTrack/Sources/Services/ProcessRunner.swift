import Foundation

/// Runs external processes (ffmpeg, yt-dlp, demucs via python) with
/// line-streamed output. Lines are split on BOTH `\n` and `\r` because
/// tqdm (demucs) and yt-dlp rewrite progress lines with carriage returns.
enum ProcessRunner {

    struct RunResult: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    enum Line: Sendable {
        case stdout(String)
        case stderr(String)
        case exit(Int32)
    }

    enum RunnerError: LocalizedError {
        case launchFailed(tool: String, reason: String)
        case nonZeroExit(tool: String, code: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case let .launchFailed(tool, reason):
                return "Could not launch \(tool): \(reason)"
            case let .nonZeroExit(tool, code, stderr):
                let tail = stderr.split(separator: "\n").suffix(6).joined(separator: "\n")
                return "\(tool) exited with code \(code).\n\(tail)"
            }
        }
    }

    /// Directories prepended to PATH for every subprocess. GUI apps launched
    /// from Finder inherit only `/usr/bin:/bin:/usr/sbin:/sbin`, so Homebrew
    /// and pipx locations must be added explicitly — yt-dlp and demucs both
    /// shell out to ffmpeg and need to find it.
    static var defaultSearchPaths: [String] {
        [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin"),
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
    }

    static func environment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var paths = defaultSearchPaths
        if let existing = env["PATH"] {
            paths.append(contentsOf: existing.split(separator: ":").map(String.init))
        }
        var seen = Set<String>()
        env["PATH"] = paths.filter { seen.insert($0).inserted }.joined(separator: ":")
        for (key, value) in extra { env[key] = value }
        return env
    }

    /// Streams stdout/stderr lines as they arrive, followed by a final
    /// `.exit(code)` element. Cancelling the consuming task terminates
    /// the process.
    static func stream(
        _ tool: URL,
        _ arguments: [String],
        environment: [String: String]? = nil
    ) -> AsyncThrowingStream<Line, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            process.environment = environment ?? Self.environment()
            process.standardInput = FileHandle.nullDevice

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: RunnerError.launchFailed(
                    tool: tool.lastPathComponent, reason: error.localizedDescription))
                return
            }

            continuation.onTermination = { termination in
                if case .cancelled = termination, process.isRunning {
                    process.terminate()
                }
            }

            Task.detached(priority: .utility) {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await line in Self.lines(of: outPipe.fileHandleForReading) {
                            continuation.yield(.stdout(line))
                        }
                    }
                    group.addTask {
                        for await line in Self.lines(of: errPipe.fileHandleForReading) {
                            continuation.yield(.stderr(line))
                        }
                    }
                }
                // Both pipes hit EOF, so the process is finished or about to be;
                // this wait returns immediately.
                process.waitUntilExit()
                continuation.yield(.exit(process.terminationStatus))
                continuation.finish()
            }
        }
    }

    /// Buffered convenience for short commands (version checks, conversions).
    /// Throws on non-zero exit.
    @discardableResult
    static func run(
        _ tool: URL,
        _ arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> RunResult {
        var stdoutLines: [String] = []
        var stderrLines: [String] = []
        var exitCode: Int32 = -1

        for try await line in stream(tool, arguments, environment: environment) {
            switch line {
            case .stdout(let text): stdoutLines.append(text)
            case .stderr(let text): stderrLines.append(text)
            case .exit(let code): exitCode = code
            }
        }
        // A cancelled consumer ends the stream without the .exit element;
        // surface that as cancellation, not as a bogus non-zero exit.
        try Task.checkCancellation()

        let result = RunResult(
            exitCode: exitCode,
            stdout: stdoutLines.joined(separator: "\n"),
            stderr: stderrLines.joined(separator: "\n"))

        guard exitCode == 0 else {
            throw RunnerError.nonZeroExit(
                tool: tool.lastPathComponent, code: exitCode, stderr: result.stderr)
        }
        return result
    }

    // MARK: - Line splitting

    /// Reads a file handle to EOF on a background queue, yielding chunks
    /// split on `\n` and `\r` (tqdm progress bars only ever emit `\r`).
    private static func lines(of handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            DispatchQueue.global(qos: .utility).async {
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break } // EOF
                    buffer.append(chunk)
                    while let separatorIndex = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<separatorIndex)
                        buffer.removeSubrange(buffer.startIndex...separatorIndex)
                        if !lineData.isEmpty, let text = String(data: lineData, encoding: .utf8),
                           !text.trimmingCharacters(in: .whitespaces).isEmpty {
                            continuation.yield(text)
                        }
                    }
                }
                if !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8),
                   !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    continuation.yield(text)
                }
                try? handle.close()
                continuation.finish()
            }
        }
    }
}
