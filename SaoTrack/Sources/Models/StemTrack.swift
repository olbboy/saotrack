import Foundation

/// The stem kinds the app can produce. Which subset a separation run yields
/// depends on the selected `SeparationMode`; in 5-stem mode Demucs'
/// `htdemucs_6s` guitar output is summed into `other`.
enum StemKind: String, CaseIterable, Identifiable, Sendable {
    case vocals
    case drums
    case bass
    case piano
    case other
    /// Everything except the vocals (2-stem mode only).
    case instrumental

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }

    var symbolName: String {
        switch self {
        case .vocals: return "music.mic"
        case .drums: return "circle.grid.2x2"
        case .bass: return "waveform.path"
        case .piano: return "pianokeys"
        case .other: return "guitars"
        case .instrumental: return "music.note.list"
        }
    }
}

/// A single playable/mixable track: either the original mix (kind == nil)
/// or one of the separated stems.
struct StemTrack: Identifiable, Sendable {
    let id: UUID
    let kind: StemKind?
    let name: String
    let url: URL
    var volume: Float = 1.0
    /// Stereo pan, -1 (full left) … 0 (center) … +1 (full right).
    var pan: Float = 0
    var isMuted = false
    var isSoloed = false

    init(id: UUID = UUID(), kind: StemKind?, name: String, url: URL) {
        self.id = id
        self.kind = kind
        self.name = name
        self.url = url
    }

    static func original(url: URL, title: String) -> StemTrack {
        StemTrack(kind: nil, name: title, url: url)
    }
}
