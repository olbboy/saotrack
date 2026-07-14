import AVFoundation
import Foundation

/// Renders exports:
/// - "Export Mix": a throwaway AVAudioEngine in offline manual-rendering
///   mode replays every audible track at its effective gain and writes a
///   16-bit WAV.
/// - "Export All Stems" / single stem: 16-bit WAV conversion per stem.
/// - MP3 320 kbps CBR: the WAV is transcoded by ffmpeg (AVFoundation has
///   no MP3 encoder); a temp WAV file is used deliberately — piping WAV
///   through stdin needs RIFF-header workarounds and worse error handling.
actor ExportService {

    /// A track prepared for offline rendering: URL + effective gain
    /// (volume with mute/solo already applied by the mixer).
    struct MixInput: Sendable {
        let url: URL
        let gain: Float
    }

    // MARK: - Mix

    func exportMix(
        inputs: [MixInput],
        masterVolume: Float,
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
            try renderMix(inputs: audible, masterVolume: masterVolume,
                          to: destination, progress: progress)
        case .mp3_320:
            let ffmpeg = try requireFFmpeg(tools)
            let tempWav = FileManager.default.temporaryDirectory
                .appendingPathComponent("saotrack-mix-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: tempWav) }
            try renderMix(inputs: audible, masterVolume: masterVolume, to: tempWav) { fraction in
                progress(fraction * 0.9)
            }
            try await encodeMP3(ffmpeg: ffmpeg, input: tempWav, output: destination)
            progress(1.0)
        }
    }

    private func renderMix(
        inputs: [MixInput],
        masterVolume: Float,
        to destination: URL,
        progress: @Sendable (Double) -> Void
    ) throws {
        let engine = AVAudioEngine()
        var players: [(AVAudioPlayerNode, AVAudioFile)] = []
        var totalFrames: AVAudioFramePosition = 0

        guard let renderFormat = AVAudioFormat(
            standardFormatWithSampleRate: 44100, channels: 2) else {
            throw AppError.exportFailed("Could not create the render format.")
        }

        for input in inputs {
            let file = try AVAudioFile(forReading: input.url)
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            player.volume = input.gain
            players.append((player, file))
            let frames = AVAudioFramePosition(
                Double(file.length) * 44100.0 / file.processingFormat.sampleRate)
            totalFrames = max(totalFrames, frames)
        }
        engine.mainMixerNode.outputVolume = masterVolume

        try? FileManager.default.removeItem(at: destination)
        try engine.enableManualRenderingMode(
            .offline, format: renderFormat, maximumFrameCount: 4096)
        try engine.start()
        for (player, file) in players {
            player.scheduleFile(file, at: nil)
            player.play()
        }

        let outFile = try AVAudioFile(
            forWriting: destination,
            settings: AudioFileHelpers.int16WavSettings(sampleRate: 44100, channels: 2),
            commonFormat: renderFormat.commonFormat,
            interleaved: renderFormat.isInterleaved)

        guard let renderBuffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw AppError.exportFailed("Could not allocate the render buffer.")
        }

        var consecutiveStalls = 0
        while engine.manualRenderingSampleTime < totalFrames {
            try Task.checkCancellation()
            let remaining = totalFrames - engine.manualRenderingSampleTime
            let framesToRender = AVAudioFrameCount(min(
                AVAudioFramePosition(renderBuffer.frameCapacity), remaining))
            let status = try engine.renderOffline(framesToRender, to: renderBuffer)
            switch status {
            case .success:
                consecutiveStalls = 0
                try outFile.write(from: renderBuffer)
                progress(Double(engine.manualRenderingSampleTime) / Double(totalFrames))
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

    /// Writes vocals.wav, drums.wav, bass.wav, piano.wav, other.wav (or .mp3)
    /// into `directory`.
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
