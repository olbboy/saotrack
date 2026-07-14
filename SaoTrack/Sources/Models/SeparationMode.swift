import Foundation

/// Which Demucs model/configuration a separation run uses, and which stems
/// it yields. Selected in the transport bar before separating.
enum SeparationMode: String, CaseIterable, Identifiable, Sendable {
    /// Vocals + Instrumental (htdemucs with --two-stems).
    case twoStems
    /// Vocals / Drums / Bass / Other (htdemucs).
    case fourStems
    /// Vocals / Drums / Bass / Piano / Other (htdemucs_6s, guitar summed
    /// into Other). The default.
    case fiveStems

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .twoStems: return "2 Stems"
        case .fourStems: return "4 Stems"
        case .fiveStems: return "5 Stems"
        }
    }

    /// Transport-bar subtitle, e.g. "Vocals / Drums / Bass / Piano / Other".
    var stemSummary: String {
        stemKinds.map(\.displayName).joined(separator: " / ")
    }

    var modelName: String {
        switch self {
        case .twoStems, .fourStems: return "htdemucs"
        case .fiveStems: return "htdemucs_6s"
        }
    }

    /// Extra demucs CLI arguments beyond the model selection.
    var extraArguments: [String] {
        switch self {
        case .twoStems: return ["--two-stems", "vocals"]
        case .fourStems, .fiveStems: return []
        }
    }

    /// The app-facing stems this mode produces, in mixer order.
    var stemKinds: [StemKind] {
        switch self {
        case .twoStems: return [.vocals, .instrumental]
        case .fourStems: return [.vocals, .drums, .bass, .other]
        case .fiveStems: return [.vocals, .drums, .bass, .piano, .other]
        }
    }
}
