import Foundation

/// The five stem kinds produced by separation. Demucs' `htdemucs_6s` model
/// emits a sixth stem (guitar) which is summed into `other` after separation.
enum StemKind: String, CaseIterable, Identifiable, Sendable {
    case vocals
    case drums
    case bass
    case piano
    case other

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }

    var symbolName: String {
        switch self {
        case .vocals: return "music.mic"
        case .drums: return "circle.grid.2x2"
        case .bass: return "waveform.path"
        case .piano: return "pianokeys"
        case .other: return "guitars"
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
