import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Imports any supported audio/video file and normalizes it to a stereo
/// 44.1 kHz WAV inside a fresh session directory. Everything downstream
/// (playback, demucs, analysis, export) consumes that WAV.
struct MediaImporter {

    static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "flac"]
    static let avVideoExtensions: Set<String> = ["mp4", "mov"]
    /// Containers AVFoundation cannot open — extracted with ffmpeg instead.
    static let ffmpegOnlyExtensions: Set<String> = ["mkv", "webm"]

    static var allExtensions: [String] {
        Array(audioExtensions) + Array(avVideoExtensions) + Array(ffmpegOnlyExtensions)
    }

    /// Content types for file pickers and drop targets.
    static var supportedContentTypes: [UTType] {
        allExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    static func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return audioExtensions.contains(ext)
            || avVideoExtensions.contains(ext)
            || ffmpegOnlyExtensions.contains(ext)
    }

    let targetSampleRate: Double = 44100
    let targetChannels: AVAudioChannelCount = 2

    func importMedia(
        from sourceURL: URL,
        tools: ToolSet,
        status: @Sendable @escaping (String) -> Void
    ) async throws -> LoadedMedia {
        let ext = sourceURL.pathExtension.lowercased()
        guard Self.isSupported(sourceURL) else {
            throw AppError.unsupportedFile(
                "\(sourceURL.lastPathComponent) — supported formats: MP3, WAV, M4A, AAC, FLAC, MP4, MOV, MKV, WEBM.")
        }

        let sessionDirectory = ToolLocator.sessionsDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let wavURL = sessionDirectory.appendingPathComponent("original.wav")

        if Self.ffmpegOnlyExtensions.contains(ext) {
            status("Extracting audio with ffmpeg…")
            try await extractWithFFmpeg(sourceURL: sourceURL, wavURL: wavURL, tools: tools)
        } else {
            status("Decoding audio…")
            try await decodeWithAVFoundation(sourceURL: sourceURL, wavURL: wavURL)
        }

        guard let duration = AudioFileHelpers.duration(of: wavURL), duration > 0 else {
            throw AppError.importFailed("The file contains no playable audio.")
        }

        return LoadedMedia(
            sourceURL: sourceURL,
            playableWavURL: wavURL,
            sessionDirectory: sessionDirectory,
            title: sourceURL.deletingPathExtension().lastPathComponent,
            duration: duration,
            sampleRate: targetSampleRate)
    }

    // MARK: - AVFoundation path (audio files + MP4/MOV video)

    /// One decode path for both audio files and video containers:
    /// AVAssetReader with an audio-mix output resampling to 44.1 kHz stereo.
    private func decodeWithAVFoundation(sourceURL: URL, wavURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw AppError.importFailed("No audio track found in \(sourceURL.lastPathComponent).")
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: targetChannels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AppError.importFailed("Could not read the audio track.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AppError.importFailed(reader.error?.localizedDescription ?? "Could not start decoding.")
        }

        guard let bufferFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: true) else {
            throw AppError.importFailed("Could not create the decode format.")
        }
        let outFile = try AVAudioFile(
            forWriting: wavURL,
            settings: AudioFileHelpers.int16WavSettings(
                sampleRate: targetSampleRate, channels: targetChannels),
            commonFormat: .pcmFormatFloat32,
            interleaved: true)

        try await Task.detached(priority: .userInitiated) {
            while let sampleBuffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
                guard frameCount > 0,
                      let pcmBuffer = AVAudioPCMBuffer(pcmFormat: bufferFormat, frameCapacity: frameCount),
                      let channelData = pcmBuffer.floatChannelData else { continue }
                pcmBuffer.frameLength = frameCount
                let byteCount = Int(frameCount) * Int(bufferFormat.streamDescription.pointee.mBytesPerFrame)
                let status = CMBlockBufferCopyDataBytes(
                    blockBuffer, atOffset: 0, dataLength: byteCount,
                    destination: channelData[0])
                guard status == kCMBlockBufferNoErr else { continue }
                try outFile.write(from: pcmBuffer)
            }
            if reader.status == .failed {
                throw AppError.importFailed(reader.error?.localizedDescription ?? "Decoding failed.")
            }
        }.value
    }

    // MARK: - ffmpeg path (MKV / WEBM)

    private func extractWithFFmpeg(sourceURL: URL, wavURL: URL, tools: ToolSet) async throws {
        guard let ffmpeg = tools.ffmpeg else {
            throw AppError.toolMissing(
                tool: "ffmpeg",
                hint: "MKV/WEBM files need ffmpeg. Install it with: brew install ffmpeg (see Setup).")
        }
        do {
            try await ProcessRunner.run(ffmpeg, [
                "-y", "-i", sourceURL.path,
                "-vn",
                "-ac", "\(targetChannels)",
                "-ar", "\(Int(targetSampleRate))",
                "-c:a", "pcm_s16le",
                wavURL.path,
            ])
        } catch {
            throw AppError.importFailed(error.localizedDescription)
        }
    }
}
