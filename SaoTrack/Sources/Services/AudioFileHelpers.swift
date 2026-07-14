import AVFoundation
import Accelerate

/// Small WAV utilities shared by separation (guitar→other merge) and export.
enum AudioFileHelpers {

    static let chunkFrames: AVAudioFrameCount = 32768

    static func int16WavSettings(sampleRate: Double, channels: UInt32) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }

    /// Sums two WAV files sample-by-sample into a 16-bit WAV, clipping to
    /// [-1, 1]. Both inputs come from the same demucs run so they share
    /// format and length; trailing frames of the longer file pass through.
    static func sumWavFiles(_ first: URL, _ second: URL, output: URL) throws {
        let fileA = try AVAudioFile(forReading: first)
        let fileB = try AVAudioFile(forReading: second)
        let format = fileA.processingFormat

        let outFile = try AVAudioFile(
            forWriting: output,
            settings: int16WavSettings(sampleRate: format.sampleRate, channels: format.channelCount),
            commonFormat: .pcmFormatFloat32,
            interleaved: false)

        guard let bufferA = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames),
              let bufferB = AVAudioPCMBuffer(pcmFormat: fileB.processingFormat, frameCapacity: chunkFrames) else {
            throw AppError.separationFailed("Could not allocate audio buffers.")
        }

        var lowClip: Float = -1.0
        var highClip: Float = 1.0

        while true {
            bufferA.frameLength = 0
            bufferB.frameLength = 0
            if fileA.framePosition < fileA.length { try fileA.read(into: bufferA) }
            if fileB.framePosition < fileB.length { try fileB.read(into: bufferB) }
            let framesA = Int(bufferA.frameLength)
            let framesB = Int(bufferB.frameLength)
            if framesA == 0 && framesB == 0 { break }

            let shared = min(framesA, framesB)
            let total = max(framesA, framesB)
            let longer = framesA >= framesB ? bufferA : bufferB

            guard let channelsA = bufferA.floatChannelData,
                  let channelsB = bufferB.floatChannelData,
                  let channelsLonger = longer.floatChannelData else { break }

            for channel in 0..<Int(format.channelCount) {
                if shared > 0 {
                    vDSP_vadd(channelsA[channel], 1, channelsB[channel], 1,
                              channelsA[channel], 1, vDSP_Length(shared))
                }
                if total > shared, longer !== bufferA {
                    // Copy the tail of the longer buffer into A's channel data.
                    channelsA[channel].advanced(by: shared)
                        .update(from: channelsLonger[channel].advanced(by: shared),
                                count: total - shared)
                }
                vDSP_vclip(channelsA[channel], 1, &lowClip, &highClip,
                           channelsA[channel], 1, vDSP_Length(total))
            }
            bufferA.frameLength = AVAudioFrameCount(total)
            try outFile.write(from: bufferA)
        }
    }

    /// Re-writes any readable audio file as 16-bit / source-rate WAV
    /// (demucs stems can be float WAV; the export contract is 16-bit).
    static func convertToInt16Wav(input: URL, output: URL) throws {
        let inFile = try AVAudioFile(forReading: input)
        let format = inFile.processingFormat
        let outFile = try AVAudioFile(
            forWriting: output,
            settings: int16WavSettings(sampleRate: format.sampleRate, channels: format.channelCount),
            commonFormat: .pcmFormatFloat32,
            interleaved: false)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw AppError.exportFailed("Could not allocate audio buffer.")
        }
        while inFile.framePosition < inFile.length {
            buffer.frameLength = 0
            try inFile.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try outFile.write(from: buffer)
        }
    }

    static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
