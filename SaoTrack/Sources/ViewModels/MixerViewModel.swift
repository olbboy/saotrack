import Foundation
import Observation

/// Owns the track list and the mute/solo/volume logic. The playback engine
/// only ever receives a single "effective gain" per track, so this class is
/// the sole source of truth for mixer state.
@MainActor
@Observable
final class MixerViewModel {

    private(set) var tracks: [StemTrack] = []
    private weak var engine: AudioPlayerEngine?

    func attach(engine: AudioPlayerEngine) {
        self.engine = engine
    }

    func setTracks(_ newTracks: [StemTrack]) {
        tracks = newTracks
        applyGains()
        applyPans()
    }

    var isSeparated: Bool { tracks.count > 1 }

    var anySoloActive: Bool { tracks.contains { $0.isSoloed } }

    func setVolume(_ volume: Float, for trackID: UUID) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        tracks[index].volume = max(0, min(1, volume))
        applyGains()
    }

    func toggleMute(for trackID: UUID) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        tracks[index].isMuted.toggle()
        applyGains()
    }

    func toggleSolo(for trackID: UUID) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        tracks[index].isSoloed.toggle()
        applyGains()
    }

    func setPan(_ pan: Float, for trackID: UUID) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        var clamped = max(-1, min(1, pan))
        if abs(clamped) < 0.06 { clamped = 0 } // snap to center
        tracks[index].pan = clamped
        engine?.setPan(clamped, for: trackID)
    }

    // MARK: - Presets

    /// Everything back to unity: full volume, center pan, no mute/solo.
    func resetMix() {
        for index in tracks.indices {
            tracks[index].volume = 1
            tracks[index].pan = 0
            tracks[index].isMuted = false
            tracks[index].isSoloed = false
        }
        applyGains()
        applyPans()
    }

    /// Karaoke: mute only the vocals, everything else audible.
    func applyKaraokePreset() {
        guard isSeparated else { return }
        for index in tracks.indices {
            tracks[index].isSoloed = false
            tracks[index].isMuted = tracks[index].kind == .vocals
        }
        applyGains()
    }

    /// Acapella: solo the vocals.
    func applyAcapellaPreset() {
        guard isSeparated else { return }
        for index in tracks.indices {
            tracks[index].isMuted = false
            tracks[index].isSoloed = tracks[index].kind == .vocals
        }
        applyGains()
    }

    /// Volume combined with mute/solo: when any track is soloed, only the
    /// soloed tracks are audible; otherwise muted tracks are silent.
    func effectiveGain(for track: StemTrack) -> Float {
        if anySoloActive {
            return track.isSoloed ? track.volume : 0
        }
        return track.isMuted ? 0 : track.volume
    }

    /// Inputs for the offline mix render, one per track with its live gain.
    func mixInputs() -> [ExportService.MixInput] {
        tracks.map { ExportService.MixInput(url: $0.url, gain: effectiveGain(for: $0)) }
    }

    private func applyGains() {
        guard let engine else { return }
        for track in tracks {
            engine.setGain(effectiveGain(for: track), for: track.id)
        }
    }

    private func applyPans() {
        guard let engine else { return }
        for track in tracks {
            engine.setPan(track.pan, for: track.id)
        }
    }
}
