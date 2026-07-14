import AVFoundation
import Foundation

/// Renders exports:
/// - "Export Mix" / "Export Loop Region": a throwaway AVAudioEngine in
///   offline manual-rendering mode replays every audible track through the
///   same gain → pan → time-pitch chain the live player uses, so the file
///   matches what the user hears (including transpose and speed).
/// - "Export All Stems" / single stem: 16-bit WAV conversion per stem
///   (always raw — DAW handoff wants the untouched material).
/// - MP3 320 kbps CBR: the WAV is transcoded by ffmpeg (AVFoundation has
///   no MP3 encoder); a temp WAV file is used deliberately — piping WAV
///   through stdin needs RIFF-header workarounds and worse error handling.
actor ExportService {

    /// A track prepared for offline rendering: URL + effective gain
    /// (volume with mute/solo already applied by the mixer) + pan.
    struct MixInput: Sendable {
        let url: URL
        let gain: Float
        let pan: Float
    }

    /// Playback shaping applied to mix renders so the export matches the
    /// live sound. `timeRange` restricts the render to the A–B loop region.
    struct MixSettings: Sendable {
        var masterVolume: Float = 1
        var pitchSemitones: Float = 0
        var playbackRate: Float = 1
        var timeRange: ClosedRange<TimeInterval>?

        var isNeutralPitchAndSpeed: Bool {
            pitchSemitones == 0 && abs(playbackRate - 1) < 0.001
        }
    }

    private static let renderSampleRate = 44100.0

    // MARK: - Mix

    func exportMix(
        inputs: [MixInput],
        settings: MixSettings,
        format: ExportFormat,
        to destination: URL,
        tools: ToolSet,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        let audible = inputs.filter { $0.gain > 0 }
        guard !audible.isEmpty else {
            throw AppError.exportFailed("Every track is muted — there is nothing to export.")
        }

        switch format {
        case .wav16:
            try renderMix(inputs: audible, settings: settings,
                          to: destination, progress: progress)
        case .mp3_320:
            let ffmpeg = try requireFFmpeg(tools)
            let tempWav = FileManager.default.temporaryDirectory
                .appendingPathComponent("saotrack-mix-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: tempWav) }
            try renderMix(inputs: audible, settings: settings, to: tempWav) { fraction in
                progress(fraction * 0.9)
            }
            try await encodeMP3(ffmpeg: ffmpeg, input: tempWav, output: destination)
            progress(1.0)
        }
    }

    private func renderMix(
        inputs: [MixInput],
        settings: MixSettings,
        to destination: URL,
        progress: @Sendable (Double) -> Void
    ) throws {
        let engine = AVAudioEngine()
        let submix = AVAudioMixerNode()
        let timePitch = AVAudioUnitTimePitch()
        engine.attach(submix)
        engine.attach(timePitch)

        let rate = max(0.25, min(2.0, settings.playbackRate))
        timePitch.pitch = settings.pitchSemitones * 100
        timePitch.rate = rate
        timePitch.bypass = settings.isNeutralPitchAndSpeed

        guard let renderFormat = AVAudioFormat(
            standardFormatWithSampleRate: Self.renderSampleRate, channels: 2) else {
            throw AppError.exportFailed("Could not create the render format.")
        }

        // Longest scheduled slice (seconds of source material) across inputs.
        var players: [(AVAudioPlayerNode, AVAudioFile, AVAudioFramePosition, AVAudioFrameCount)] = []
        var sourceSeconds: Double = 0

        for input in inputs {
            let file = try AVAudioFile(forReading: input.url)
            let fileRate = file.processingFormat.sampleRate
            let fileSeconds = Double(file.length) / fileRate

            var startFrame: AVAudioFramePosition = 0
            var sliceSeconds = fileSeconds
            if let range = settings.timeRange {
                let start = max(0, min(range.lowerBound, fileSeconds))
                let end = max(start, min(range.upperBound, fileSeconds))
                sliceSeconds = end - start
                startFrame = AVAudioFramePosition(start * fileRate)
            }
            let frameCount = AVAudioFrameCount(sliceSeconds * fileRate)
            guard frameCount > 0 else { continue } // slice past this file's end

            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: submix, format: file.processingFormat)
            player.volume = input.gain
            player.pan = input.pan
            players.append((player, file, startFrame, frameCount))
            sourceSeconds = max(sourceSeconds, sliceSeconds)
        }
        guard !players.isEmpty, sourceSeconds > 0 else {
            throw AppError.exportFailed("The selected region contains no audio.")
        }

        engine.connect(submix, to: timePitch, format: renderFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: renderFormat)
        engine.mainMixerNode.outputVolume = settings.masterVolume

        try? FileManager.default.removeItem(at: destination)
        try engine.enableManualRenderingMode(
            .offline, format: renderFormat, maximumFrameCount: 4096)
        try engine.start()
        for (player, file, startFrame, frameCount) in players {
            player.scheduleSegment(
                file, startingFrame: startFrame, frameCount: frameCount, at: nil)
            player.play()
        }

        // A non-neutral time-pitch stretches the timeline (output length =
        // source / rate) and delays its output by its processing latency.
        // Render latency extra frames and drop the leading latency so the
        // file starts on the actual first sample and nothing is cut short.
        let sourceFrames = AVAudioFramePosition(sourceSeconds * Self.renderSampleRate)
        let outputFrames = timePitch.bypass
            ? sourceFrames
            : AVAudioFramePosition((sourceSeconds / Double(rate)) * Self.renderSampleRate)
        var framesToSkip = timePitch.bypass
            ? 0
            : Int((timePitch.auAudioUnit.latency * Self.renderSampleRate).rounded(.up))
        let totalToRender = outputFrames + AVAudioFramePosition(framesToSkip)

        let outFile = try AVAudioFile(
            forWriting: destination,
            settings: AudioFileHelpers.int16WavSettings(
                sampleRate: Self.renderSampleRate, channels: 2),
            commonFormat: renderFormat.commonFormat,
            interleaved: renderFormat.isInterleaved)

        guard let renderBuffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw AppError.exportFailed("Could not allocate the render buffer.")
        }

        var consecutiveStalls = 0
        while engine.manualRenderingSampleTime < totalToRender {
            try Task.checkCancellation()
            let remaining = totalToRender - engine.manualRenderingSampleTime
            let framesToRender = AVAudioFrameCount(min(
                AVAudioFramePosition(renderBuffer.frameCapacity), remaining))
            let status = try engine.renderOffline(framesToRender, to: renderBuffer)
            switch status {
            case .success:
                consecutiveStalls = 0
                try write(renderBuffer, to: outFile, skippingFirst: &framesToSkip)
                progress(Double(engine.manualRenderingSampleTime) / Double(totalToRender))
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                consecutiveStalls += 1
                guard consecutiveStalls < 64 else {
                    throw AppError.exportFailed("Offline rendering stalled.")
                }
                continue
            case .error:
                throw AppError.exportFailed("Offline rendering failed.")
            @unknown default:
                throw AppError.exportFailed("Offline rendering failed.")
            }
        }

        engine.stop()
        progress(1.0)
    }

    /// Writes `buffer`, dropping the first `skip` frames (the time-pitch
    /// unit's latency padding) across however many buffers it spans.
    private func write(
        _ buffer: AVAudioPCMBuffer,
        to file: AVAudioFile,
        skippingFirst skip: inout Int
    ) throws {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        if skip >= frames {
            skip -= frames
            return
        }
        if skip > 0 {
            guard let channels = buffer.floatChannelData else { return }
            let remaining = frames - skip
            for channel in 0..<Int(buffer.format.channelCount) {
                channels[channel].update(from: channels[channel] + skip, count: remaining)
            }
            buffer.frameLength = AVAudioFrameCount(remaining)
            skip = 0
        }
        try file.write(from: buffer)
    }

    // MARK: - Stems

    func exportStem(
        url: URL,
        format: ExportFormat,
        to destination: URL,
        tools: ToolSet
    ) async throws {
        switch format {
        case .wav16:
            try? FileManager.default.removeItem(at: destination)
            try AudioFileHelpers.convertToInt16Wav(input: url, output: destination)
        case .mp3_320:
            let ffmpeg = try requireFFmpeg(tools)
            try await encodeMP3(ffmpeg: ffmpeg, input: url, output: destination)
        }
    }

    /// Writes one file per stem (e.g. vocals.wav, drums.wav, …) into `directory`.
    func exportAllStems(
        stems: [(kind: StemKind, url: URL)],
        format: ExportFormat,
        to directory: URL,
        tools: ToolSet,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        for (index, stem) in stems.enumerated() {
            try Task.checkCancellation()
            let destination = directory
                .appendingPathComponent("\(stem.kind.rawValue).\(format.fileExtension)")
            try? FileManager.default.removeItem(at: destination)
            try await exportStem(url: stem.url, format: format, to: destination, tools: tools)
            progress(Double(index + 1) / Double(stems.count))
        }
    }

    // MARK: - MP3 via ffmpeg

    private func requireFFmpeg(_ tools: ToolSet) throws -> URL {
        guard let ffmpeg = tools.ffmpeg else {
            throw AppError.toolMissing(
                tool: "ffmpeg",
                hint: "MP3 export needs ffmpeg. Install it with: brew install ffmpeg (see Setup).")
        }
        return ffmpeg
    }

    private func encodeMP3(ffmpeg: URL, input: URL, output: URL) async throws {
        do {
            try await ProcessRunner.run(ffmpeg, [
                "-y", "-i", input.path,
                "-vn",
                "-codec:a", "libmp3lame",
                "-b:a", "320k",
                output.path,
            ])
        } catch {
            throw AppError.exportFailed(error.localizedDescription)
        }
    }
}
