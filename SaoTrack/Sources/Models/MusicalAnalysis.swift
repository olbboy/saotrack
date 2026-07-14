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

    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// The key this song sounds in when transposed by `semitones`
    /// (e.g. "A Minor" + 2 → "B Minor"); nil if `keyName` can't be parsed.
    func transposedKeyName(by semitones: Int) -> String? {
        let parts = keyName.split(separator: " ", maxSplits: 1)
        guard parts.count == 2,
              let tonic = Self.noteNames.firstIndex(of: String(parts[0])) else { return nil }
        let shifted = ((tonic + semitones) % 12 + 12) % 12
        return "\(Self.noteNames[shifted]) \(parts[1])"
    }
}
