import AVFoundation
import Accelerate

/// Extracts a downsampled peak envelope from an audio file for the seek
/// waveform. CPU-bound; call from a detached task.
enum WaveformGenerator {

    /// Per-bucket peak amplitudes, normalized to 0…1.
    static func peaks(for url: URL, bucketCount: Int = 1200) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let totalFrames = Int(file.length)
        guard totalFrames > 0, bucketCount > 0 else { return [] }

        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        let framesPerBucket = max(1, totalFrames / bucketCount)
        let chunkFrames: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            return []
        }

        var peaks = [Float](repeating: 0, count: bucketCount)
        var frameIndex = 0

        while file.framePosition < file.length {
            buffer.frameLength = 0
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let channels = buffer.floatChannelData else { break }

            for channel in 0..<channelCount {
                var offset = 0
                while offset < frames {
                    let globalFrame = frameIndex + offset
                    let bucket = min(globalFrame / framesPerBucket, bucketCount - 1)
                    let bucketEndFrame = (bucket + 1) * framesPerBucket
                    let length = min(frames - offset, max(1, bucketEndFrame - globalFrame))
                    var magnitude: Float = 0
                    vDSP_maxmgv(channels[channel] + offset, 1, &magnitude, vDSP_Length(length))
                    if magnitude > peaks[bucket] { peaks[bucket] = magnitude }
                    offset += length
                }
            }
            frameIndex += frames
        }

        if let maxPeak = peaks.max(), maxPeak > 0 {
            var scale = 1 / maxPeak
            vDSP_vsmul(peaks, 1, &scale, &peaks, 1, vDSP_Length(bucketCount))
        }
        return peaks
    }
}
