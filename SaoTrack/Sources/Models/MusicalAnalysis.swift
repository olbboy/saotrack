import Foundation

/// Result of the "Detect Key & BPM" analysis.
struct MusicalAnalysis: Sendable, Equatable {
    /// e.g. "A Minor", "C Major"
    let keyName: String
    /// Margin of the best key-profile correlation over the runner-up (0...1-ish).
    let keyConfidence: Double
    /// Estimated tempo in beats per minute.
    let bpm: Double

    var bpmDisplay: String {
        bpm.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", bpm)
            : String(format: "%.1f", bpm)
    }
}
