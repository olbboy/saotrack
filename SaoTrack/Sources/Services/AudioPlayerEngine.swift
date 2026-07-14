import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import Observation

/// Plays 1..n tracks (the original mix, or the five stems) in sample-accurate
/// sync: one AVAudioPlayerNode per track feeding a private stem mixer, which
/// runs through a time-pitch unit (live transpose / speed) into the output.
///
/// Sync strategy — a single code path (`startAll(fromFrame:)`) serves play,
/// resume, and seek: every node is stopped, rescheduled from the same file
/// frame, and started at a common host time ~120 ms in the future so all
/// nodes begin on the same hardware tick. Resuming with a bare `play()`
/// after `pause()` is deliberately avoided: it can drift nodes apart by a
/// render buffer.
///
/// All positions (`currentTime`, loop points) are expressed in *file* time,
/// so they stay musically meaningful when the playback rate is not 1x.
@MainActor
@Observable
final class AudioPlayerEngine {

    enum PlaybackState: Equatable {
        case stopped
        case playing
        case paused
    }

    private let engine = AVAudioEngine()
    /// All player nodes mix here, upstream of the time-pitch unit.
    private let stemMixer = AVAudioMixerNode()
    private let timePitch = AVAudioUnitTimePitch()
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
    // @ObservationIgnored keeps these genuinely stored properties so the
    // nonisolated deinit may access them.
    @ObservationIgnored private var configurationChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var loopTimer: Timer?

    private(set) var state: PlaybackState = .stopped
    private(set) var duration: TimeInterval = 0
    private(set) var sampleRate: Double = 44100

    /// Per-track output level (0…1 peak, post-gain), fed by render taps.
    private(set) var trackLevels: [UUID: Float] = [:]

    // MARK: - Loop region (A–B repeat)

    private(set) var loopStart: TimeInterval?
    private(set) var loopEnd: TimeInterval?
    var isLoopEnabled = false

    // MARK: - Speed trainer

    /// When enabled with an active loop, every completed pass raises the
    /// playback rate by `trainerStepPercent` until it reaches 100% — start
    /// slow, finish at full speed.
    var trainerEnabled = false
    var trainerStepPercent = 2

    private func advanceTrainerIfNeeded() {
        guard trainerEnabled, playbackRate < 0.999 else { return }
        let next = playbackRate + Float(trainerStepPercent) / 100
        playbackRate = min(1.0, (next * 100).rounded() / 100)
    }

    var hasLoopRegion: Bool {
        if let start = loopStart, let end = loopEnd, end > start { return true }
        return false
    }

    var onPlaybackEnded: (() -> Void)?

    var masterVolume: Float = 1.0 {
        didSet { engine.mainMixerNode.outputVolume = max(0, min(1, masterVolume)) }
    }

    // MARK: - Pitch & speed

    /// Live transpose in semitones (-12…+12); does not affect exports.
    var pitchSemitones: Float = 0 {
        didSet { updateTimePitch() }
    }

    /// Live playback rate (0.5…1.5); positions stay in file time.
    var playbackRate: Float = 1.0 {
        didSet { updateTimePitch() }
    }

    private func updateTimePitch() {
        timePitch.pitch = pitchSemitones * 100 // cents
        timePitch.rate = max(0.25, min(2.0, playbackRate))
        // Bypass when neutral so the pitch algorithm never colors the sound.
        timePitch.bypass = pitchSemitones == 0 && abs(playbackRate - 1.0) < 0.001
    }

    init() {
        engine.attach(stemMixer)
        engine.attach(timePitch)
        updateTimePitch()
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
        loopTimer?.invalidate()
    }

    // MARK: - Loading

    func load(tracks: [StemTrack]) throws {
        stop()
        for player in players.values {
            player.removeTap(onBus: 0)
            engine.detach(player)
        }
        players.removeAll()
        audioFiles.removeAll()
        trackLevels.removeAll()
        referenceTrackID = nil
        duration = 0
        clearLoop()
        pitchSemitones = 0
        playbackRate = 1.0
        trainerEnabled = false

        var chainSampleRate: Double = 44100
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
            engine.connect(player, to: stemMixer, format: file.processingFormat)
            player.volume = track.volume
            player.pan = track.pan
            installLevelTap(on: player, trackID: track.id)
            players[track.id] = player
            audioFiles[track.id] = file

            let trackDuration = Double(file.length) / file.processingFormat.sampleRate
            if trackDuration > duration {
                duration = trackDuration
                referenceTrackID = track.id
                sampleRate = file.processingFormat.sampleRate
                chainSampleRate = file.processingFormat.sampleRate
            }
        }

        if !tracks.isEmpty {
            let chainFormat = AVAudioFormat(
                standardFormatWithSampleRate: chainSampleRate, channels: 2)
            engine.connect(stemMixer, to: timePitch, format: chainFormat)
            engine.connect(timePitch, to: engine.mainMixerNode, format: chainFormat)
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
        stopLoopTimer()
        resetLevels()
    }

    func stop() {
        scheduleGeneration += 1
        for player in players.values { player.stop() }
        anchorFrame = 0
        pausedAtFrame = 0
        state = .stopped
        stopLoopTimer()
        resetLevels()
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

    /// Relative seek, e.g. the ±5 s transport buttons.
    func skip(by seconds: TimeInterval) {
        guard hasTracks else { return }
        seek(to: currentTime + seconds)
    }

    var currentTime: TimeInterval {
        Double(currentFrame()) / sampleRate
    }

    var progressFraction: Double {
        duration > 0 ? min(1, currentTime / duration) : 0
    }

    // MARK: - Loop region

    func setLoopStart(_ time: TimeInterval) {
        let clamped = max(0, min(time, duration))
        loopStart = clamped
        // A start at/after the current end invalidates the region.
        if let end = loopEnd, end <= clamped {
            loopEnd = nil
            isLoopEnabled = false
        }
    }

    func setLoopEnd(_ time: TimeInterval) {
        let clamped = max(0, min(time, duration))
        if loopStart == nil { loopStart = 0 }
        guard let start = loopStart, clamped > start + 0.1 else { return }
        loopEnd = clamped
        isLoopEnabled = true
    }

    func clearLoop() {
        loopStart = nil
        loopEnd = nil
        isLoopEnabled = false
    }

    // MARK: - Gains

    /// Applies the effective gain (volume x mute/solo logic, computed by the
    /// mixer view model) to one track's player node.
    func setGain(_ gain: Float, for trackID: UUID) {
        players[trackID]?.volume = max(0, min(1, gain))
    }

    /// Stereo pan (-1…+1) for one track's player node.
    func setPan(_ pan: Float, for trackID: UUID) {
        players[trackID]?.pan = max(-1, min(1, pan))
    }

    // MARK: - Output device

    /// Routes the engine to a specific output device. Must happen while the
    /// engine is stopped; playback resumes from the captured position.
    func setOutputDevice(_ deviceID: AudioDeviceID) throws {
        let wasPlaying = state == .playing
        let frame = currentFrame()

        // Invalidate pending segment completions BEFORE stopping the players,
        // otherwise they'd count as "track finished" and reset the position.
        scheduleGeneration += 1
        for player in players.values { player.stop() }
        engine.stop()
        // If anything below throws, we're consistently paused at `frame`
        // instead of claiming to be playing on a dead engine.
        if wasPlaying {
            state = .paused
            stopLoopTimer()
        }
        pausedAtFrame = frame

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
        startLoopTimer()
    }

    private func handleSegmentCompletion(generation: Int) {
        guard generation == scheduleGeneration, state == .playing else { return }
        completedInGeneration += 1
        guard completedInGeneration >= scheduledCount else { return }
        // Loop-to-end regions restart instead of stopping.
        if isLoopEnabled, hasLoopRegion, let start = loopStart {
            advanceTrainerIfNeeded()
            startAll(fromFrame: AVAudioFramePosition(start * sampleRate))
            return
        }
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
            // sampleTime is negative during the ~120 ms pre-roll before the
            // common start tick; never report a position before the anchor.
            let frame = anchorFrame + max(0, playerTime.sampleTime)
            let maxFrame = AVAudioFramePosition(duration * sampleRate)
            return max(0, min(frame, maxFrame))
        }
    }

    private func recoverFromConfigurationChange() {
        guard hasTracks else { return }
        let wasPlaying = state == .playing
        let frame = currentFrame()
        scheduleGeneration += 1
        for player in players.values { player.stop() }
        engine.stop()
        engine.prepare()
        if wasPlaying {
            startAll(fromFrame: frame)
        } else {
            pausedAtFrame = frame
        }
    }

    // MARK: - Loop timer

    private func startLoopTimer() {
        stopLoopTimer()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.loopTimerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        loopTimer = timer
    }

    private func stopLoopTimer() {
        loopTimer?.invalidate()
        loopTimer = nil
    }

    private func loopTimerFired() {
        guard state == .playing, isLoopEnabled,
              let start = loopStart, let end = loopEnd, end > start else { return }
        if currentTime >= end {
            advanceTrainerIfNeeded()
            startAll(fromFrame: AVAudioFramePosition(start * sampleRate))
        }
    }

    // MARK: - Level metering

    /// Peak meter tap; ~10 updates/s per track at 44.1 kHz. The buffer math
    /// runs on the render thread, only the tiny result hops to the main actor.
    private func installLevelTap(on player: AVAudioPlayerNode, trackID: UUID) {
        player.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            let frames = vDSP_Length(buffer.frameLength)
            guard frames > 0 else { return }
            var peak: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                var channelPeak: Float = 0
                vDSP_maxmgv(channels[channel], 1, &channelPeak, frames)
                peak = max(peak, channelPeak)
            }
            Task { @MainActor [weak self] in
                guard let self, self.state == .playing else { return }
                // The tap sits upstream of the mixer input, so fold the
                // track's live gain in for a post-fader reading.
                let gain = self.players[trackID]?.volume ?? 0
                self.trackLevels[trackID] = min(1, peak * gain)
            }
        }
    }

    private func resetLevels() {
        trackLevels = trackLevels.mapValues { _ in 0 }
    }
}
