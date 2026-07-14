import Foundation

/// A media item that has been imported and normalized to a stereo
/// 44.1 kHz WAV inside the session working directory. Every downstream
/// consumer (playback, separation, analysis, export) reads this WAV.
struct LoadedMedia: Sendable {
    /// The file the user originally picked (or the yt-dlp download).
    let sourceURL: URL
    /// Normalized WAV used for playback / separation / analysis.
    let playableWavURL: URL
    /// Session working directory holding the WAV, stems, and temp files.
    let sessionDirectory: URL
    let title: String
    let duration: TimeInterval
    let sampleRate: Double
}
