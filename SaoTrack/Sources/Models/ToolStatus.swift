import Foundation

/// Resolved locations of the external tools the app depends on.
struct ToolSet: Sendable {
    /// ffmpeg binary (video extraction for MKV/WEBM, MP3 encoding).
    var ffmpeg: URL?
    /// yt-dlp binary (YouTube download).
    var ytDlp: URL?
    /// A python3 interpreter that can `import demucs` (stem separation).
    var demucsPython: URL?

    var hasFFmpeg: Bool { ffmpeg != nil }
    var hasYtDlp: Bool { ytDlp != nil }
    var hasDemucs: Bool { demucsPython != nil }
}

enum ToolAvailability: Sendable, Equatable {
    case unknown
    case found(path: String, version: String)
    case missing
}

/// One row in the Setup screen.
struct ToolStatus: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let purpose: String
    let installCommand: String
    var availability: ToolAvailability = .unknown
}
