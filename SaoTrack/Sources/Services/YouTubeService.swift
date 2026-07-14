import Foundation

/// Downloads the audio of a YouTube video with yt-dlp and returns the
/// resulting local file (which is then fed through MediaImporter).
actor YouTubeService {

    private static let progressPattern = try! NSRegularExpression(
        pattern: #"\[download\]\s+([\d.]+)%"#)

    func download(
        urlString: String,
        tools: ToolSet,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        guard let ytDlp = tools.ytDlp else {
            throw AppError.toolMissing(
                tool: "yt-dlp",
                hint: "Install it with: brew install yt-dlp (see Setup).")
        }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host,
              host.contains("youtube.com") || host.contains("youtu.be") else {
            throw AppError.downloadFailed("Please paste a valid YouTube link.")
        }

        let downloadDirectory = ToolLocator.downloadsDirectory
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)

        var arguments: [String] = [
            "--newline",
            "--no-playlist",
            "-f", "bestaudio",
            "-x", "--audio-format", "m4a",
            "--audio-quality", "0",
            // Byte-truncated title keeps unicode/emoji names filesystem-safe.
            "-o", downloadDirectory.appendingPathComponent("%(title).80B-%(id)s.%(ext)s").path,
            "--no-simulate",
            "--print", "after_move:filepath",
            trimmed,
        ]
        if let ffmpeg = tools.ffmpeg {
            arguments.insert(contentsOf: ["--ffmpeg-location", ffmpeg.deletingLastPathComponent().path], at: 0)
        }

        var resultPath: String?
        var stderrTail: [String] = []
        var exitCode: Int32 = -1

        for try await line in ProcessRunner.stream(ytDlp, arguments) {
            switch line {
            case .stdout(let text):
                if let fraction = Self.parseProgress(text) {
                    progress(fraction)
                } else if text.hasPrefix("/") {
                    // The `--print after_move:filepath` output.
                    resultPath = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case .stderr(let text):
                if let fraction = Self.parseProgress(text) {
                    progress(fraction)
                } else {
                    stderrTail.append(text)
                    if stderrTail.count > 10 { stderrTail.removeFirst() }
                }
            case .exit(let code):
                exitCode = code
            }
        }

        guard exitCode == 0 else {
            throw AppError.downloadFailed(stderrTail.suffix(4).joined(separator: "\n"))
        }
        guard let resultPath, FileManager.default.fileExists(atPath: resultPath) else {
            // Fallback: newest file in the download directory.
            if let newest = Self.newestFile(in: downloadDirectory) { return newest }
            throw AppError.downloadFailed("The download finished but the file could not be located.")
        }
        progress(1.0)
        return URL(fileURLWithPath: resultPath)
    }

    private static func parseProgress(_ line: String) -> Double? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = progressPattern.firstMatch(in: line, range: range),
              let percentRange = Range(match.range(at: 1), in: line),
              let percent = Double(line[percentRange]) else { return nil }
        return min(1.0, percent / 100.0)
    }

    private static func newestFile(in directory: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles)) ?? []
        return contents.max { first, second in
            let firstDate = (try? first.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let secondDate = (try? second.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return firstDate < secondDate
        }
    }
}
