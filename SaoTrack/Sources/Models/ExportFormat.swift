import Foundation

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case wav16 = "WAV 16-bit / 44.1 kHz"
    case mp3_320 = "MP3 320 kbps CBR"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .wav16: return "wav"
        case .mp3_320: return "mp3"
        }
    }

    /// MP3 encoding is delegated to ffmpeg (AVFoundation cannot encode MP3).
    var requiresFFmpeg: Bool { self == .mp3_320 }
}
