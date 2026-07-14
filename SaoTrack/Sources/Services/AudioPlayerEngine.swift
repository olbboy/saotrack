import AVFoundation
import CoreAudio
import Foundation
import Observation

/// Plays 1..n tracks (the original mix, or the five stems) in sample-accurate
/// sync: one AVAudioPlayerNode per track feeding the main mixer.
///
/// Sync strategy — a single code path (`startAll(fromFrame:)`) serves play,
/// resume, and seek: every node is stopped, rescheduled from the same file
/// frame, and started at a common host time ~120 ms in the future so all
/// nodes begin on the same hardware tick. Resuming with a bare `play()`
/// after `pause()` is deliberately avoided: it can drift nodes apart by a
/// render buffer.
@MainActor
@Observable
final class AudioPlayerEngine {

    enum PlaybackState: Equatable {
        case stopped
        case playing
        case paused
    }

    private let engine = AVAudioEngine()
    private var players: [UUID: AVAudioPlayerNode] = [:]
    private var audioFiles: [UUID: AVAudioFile] = [:]
    private var referenceTrackID: UUID?

    /// File frame where playback last (re)started; playerTime offsets add to it.
    private var anchorFrame: AVAudioFramePosition = 0
    private var pausedAtFrame: AVAudioFramePosition = 0
    /// Invalidates completion handlers of superseded schedules (every
    /// seek/stop fires the old segments' completions).
    private var scheduleGeneration = 0
    private var completedInGeneration = 0
    private var scheduledCount = 0
    private var configurationChangeObserver: NSObjectProtocol?

    private(set) var state: PlaybackState = .stopped
    private(set) var duration: TimeInterval = 0
    private(set) var sampleRate: Double = 44100

    var onPlaybackEnded: (() -> Void)?

    var masterVolume: Float = 1.0 {
        didSet { engine.mainMixerNode.outputVolume = max(0, min(1, masterVolume)) }
    }

    init() {
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            // The default device changed or was unplugged: the engine stops
            // silently. Capture the position and restart.
            Task { @MainActor in self?.recoverFromConfigurationChange() }
        }
    }

    deinit {
        if let observer = configurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Loading

    func load(tracks: [StemTrack]) throws {
        stop()
        for player in players.values {
            engine.detach(player)
        }
        players.removeAll()
        audioFiles.removeAll()
        referenceTrackID = nil
        duration = 0

        for track in tracks {
            let file: AVAudioFile
            do {
                file = try AVAudioFile(forReading: track.url)
            } catch {
                throw AppError.playbackFailed(
                    "Could not open \(track.url.lastPathComponent): \(error.localizedDescription)")
            }
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            player.volume = track.volume
            players[track.id] = player
            audioFiles[track.id] = file

            let trackDuration = Double(file.length) / file.processingFormat.sampleRate
            if trackDuration > duration {
                duration = trackDuration
                referenceTrackID = track.id
                sampleRate = file.processingFormat.sampleRate
            }
        }
        engine.mainMixerNode.outputVolume = masterVolume
        engine.prepare()
    }

    var hasTracks: Bool { !players.isEmpty }

    // MARK: - Transport

    func play() {
        guard hasTracks else { return }
        switch state {
        case .playing:
            return
        case .paused:
            startAll(fromFrame: pausedAtFrame)
        case .stopped:
            startAll(fromFrame: 0)
        }
    }

    func pause() {
        guard state == .playing else { return }
        let frame = currentFrame()
        for player in players.values { player.stop() }
        pausedAtFrame = frame
        state = .paused
    }

    func stop() {
        scheduleGeneration += 1
        for player in players.values { player.stop() }
        anchorFrame = 0
        pausedAtFrame = 0
        state = .stopped
    }

    func seek(to time: TimeInterval) {
        guard hasTracks else { return }
        let clamped = max(0, min(time, duration))
        let frame = AVAudioFramePosition(clamped * sampleRate)
        switch state {
        case .playing:
            startAll(fromFrame: frame)
        case .paused, .stopped:
            pausedAtFrame = frame
            anchorFrame = frame
            if state == .stopped { state = .paused }
        }
    }

    var currentTime: TimeInterval {
        Double(currentFrame()) / sampleRate
    }

    var progressFraction: Double {
        duration > 0 ? min(1, currentTime / duration) : 0
    }

    // MARK: - Gains

    /// Applies the effective gain (volume x mute/solo logic, computed by the
    /// mixer view model) to one track's player node.
    func setGain(_ gain: Float, for trackID: UUID) {
        players[trackID]?.volume = max(0, min(1, gain))
    }

    // MARK: - Output device

    /// Routes the engine to a specific output device. Must happen while the
    /// engine is stopped; playback resumes from the captured position.
    func setOutputDevice(_ deviceID: AudioDeviceID) throws {
        let wasPlaying = state == .playing
        let frame = currentFrame()

        if wasPlaying {
            for player in players.values { player.stop() }
        }
        engine.stop()

        guard let audioUnit = engine.outputNode.audioUnit else {
            throw AppError.playbackFailed("The audio output is unavailable.")
        }
        var mutableID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw AppError.playbackFailed("Could not switch the output device (error \(status)).")
        }

        engine.prepare()
        if wasPlaying {
            startAll(fromFrame: frame)
        } else {
            pausedAtFrame = frame
        }
    }

    // MARK: - Internals

    private func startAll(fromFrame startFrame: AVAudioFramePosition) {
        guard hasTracks else { return }

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                state = .stopped
                return
            }
        }

        scheduleGeneration += 1
        completedInGeneration = 0
        scheduledCount = 0
        let generation = scheduleGeneration

        for (trackID, player) in players {
            player.stop() // clears any queued segments
            guard let file = audioFiles[trackID] else { continue }
            let remaining = file.length - startFrame
            guard remaining > 0 else { continue }
            scheduledCount += 1
            player.scheduleSegment(
                file,
                startingFrame: startFrame,
                frameCount: AVAudioFrameCount(remaining),
                at: nil,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleSegmentCompletion(generation: generation)
                }
            }
        }

        guard scheduledCount > 0 else {
            // Seeked past the end of every track.
            stop()
            onPlaybackEnded?()
            return
        }

        // Common future start so every node begins on the same host tick.
        let startHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.12)
        let startTime = AVAudioTime(hostTime: startHostTime)
        for (trackID, player) in players where audioFiles[trackID].map({ $0.length > startFrame }) == true {
            player.play(at: startTime)
        }

        anchorFrame = startFrame
        pausedAtFrame = startFrame
        state = .playing
    }

    private func handleSegmentCompletion(generation: Int) {
        guard generation == scheduleGeneration, state == .playing else { return }
        completedInGeneration += 1
        guard completedInGeneration >= scheduledCount else { return }
        stop()
        onPlaybackEnded?()
    }

    private func currentFrame() -> AVAudioFramePosition {
        switch state {
        case .stopped:
            return 0
        case .paused:
            return pausedAtFrame
        case .playing:
            guard let referenceTrackID,
                  let player = players[referenceTrackID],
                  let nodeTime = player.lastRenderTime,
                  let playerTime = player.playerTime(forNodeTime: nodeTime) else {
                return anchorFrame
            }
            let frame = anchorFrame + playerTime.sampleTime
            let maxFrame = AVAudioFramePosition(duration * sampleRate)
            return max(0, min(frame, maxFrame))
        }
    }

    private func recoverFromConfigurationChange() {
        guard hasTracks else { return }
        let wasPlaying = state == .playing
        let frame = currentFrame()
        for player in players.values { player.stop() }
        engine.stop()
        engine.prepare()
        if wasPlaying {
            startAll(fromFrame: frame)
        } else {
            pausedAtFrame = frame
        }
    }
}
