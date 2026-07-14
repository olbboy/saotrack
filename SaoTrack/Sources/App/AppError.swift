import Foundation

enum AppError: LocalizedError, Equatable {
    case toolMissing(tool: String, hint: String)
    case unsupportedFile(String)
    case importFailed(String)
    case downloadFailed(String)
    case separationFailed(String)
    case exportFailed(String)
    case analysisFailed(String)
    case playbackFailed(String)

    var errorDescription: String? {
        switch self {
        case let .toolMissing(tool, hint):
            return "\(tool) was not found. \(hint)"
        case let .unsupportedFile(detail):
            return "Unsupported file: \(detail)"
        case let .importFailed(detail):
            return "Could not load the file: \(detail)"
        case let .downloadFailed(detail):
            return "YouTube download failed: \(detail)"
        case let .separationFailed(detail):
            return "Stem separation failed: \(detail)"
        case let .exportFailed(detail):
            return "Export failed: \(detail)"
        case let .analysisFailed(detail):
            return "Key & BPM analysis failed: \(detail)"
        case let .playbackFailed(detail):
            return "Playback error: \(detail)"
        }
    }

    static func from(_ error: Error, fallback: (String) -> AppError) -> AppError {
        if let appError = error as? AppError { return appError }
        return fallback(error.localizedDescription)
    }
}
