import AVFoundation
import Accelerate
import Foundation

/// Detects the musical key and tempo of an audio file. Pure Swift + vDSP:
/// - BPM: spectral-flux onset envelope -> autocorrelation with a comb over
///   the first harmonics, a log-Gaussian tempo prior around 120 BPM, and
///   half/double octave disambiguation into the 70–180 window.
/// - Key: FFT-folded chromagram -> Krumhansl–Schmuckler correlation against
///   the 24 major/minor key profiles.
struct AnalysisService {

    static let analysisSampleRate: Double = 22050
    static let fftSize = 2048
    static let hopSize = 512
    /// Only the middle of long files is analyzed: cheaper, and it skips
    /// intros/outros that skew both tempo and key.
    static let maxAnalysisSeconds: Double = 90

    /// Nonisolated async: runs off the main actor on the caller's task, so
    /// cancelling the owning task genuinely aborts the analysis.
    func analyze(fileURL: URL) async throws -> MusicalAnalysis {
        let samples = try Self.decodeMonoSamples(
            url: fileURL,
            targetRate: Self.analysisSampleRate,
            maxSeconds: Self.maxAnalysisSeconds)
        guard samples.count >= Self.fftSize * 4 else {
            throw AppError.analysisFailed("The file is too short to analyze.")
        }
        try Task.checkCancellation()

        let spectra = Self.stftMagnitudes(samples)
        try Task.checkCancellation()

        let frameRate = Self.analysisSampleRate / Double(Self.hopSize)
        let envelope = Self.onsetEnvelope(spectra)
        let bpm = Self.estimateBPM(envelope, frameRate: frameRate)
        try Task.checkCancellation()

        let chroma = Self.chromagram(spectra, sampleRate: Self.analysisSampleRate)
        let key = Self.estimateKey(chroma)

        return MusicalAnalysis(keyName: key.name, keyConfidence: key.confidence, bpm: bpm)
    }

    // MARK: - Decoding

    static func decodeMonoSamples(url: URL, targetRate: Double, maxSeconds: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        let totalFrames = file.length
        let maxFrames = AVAudioFramePosition(maxSeconds * sourceFormat.sampleRate)

        var framesToRead = totalFrames
        if totalFrames > maxFrames {
            file.framePosition = (totalFrames - maxFrames) / 2
            framesToRead = maxFrames
        }

        guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AppError.analysisFailed("Could not prepare the analysis converter.")
        }

        let inCapacity: AVAudioFrameCount = 65536
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inCapacity),
              let outBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(Double(inCapacity) * targetRate / sourceFormat.sampleRate) + 4096) else {
            throw AppError.analysisFailed("Could not allocate analysis buffers.")
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(framesToRead) * targetRate / sourceFormat.sampleRate) + 1024)
        var remaining = framesToRead
        var sourceDrained = false

        while true {
            outBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
                if sourceDrained || remaining <= 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                inBuffer.frameLength = 0
                let want = AVAudioFrameCount(min(AVAudioFramePosition(inCapacity), remaining))
                do {
                    try file.read(into: inBuffer, frameCount: want)
                } catch {
                    sourceDrained = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    sourceDrained = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                remaining -= AVAudioFramePosition(inBuffer.frameLength)
                outStatus.pointee = .haveData
                return inBuffer
            }
            if let conversionError {
                throw AppError.analysisFailed(conversionError.localizedDescription)
            }
            if outBuffer.frameLength > 0, let channelData = outBuffer.floatChannelData {
                samples.append(contentsOf: UnsafeBufferPointer(
                    start: channelData[0], count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || status == .error { break }
        }
        return samples
    }

    // MARK: - STFT

    /// Hann-windowed magnitude spectra, `fftSize/2` bins per frame.
    static func stftMagnitudes(_ samples: [Float]) -> [[Float]] {
        let n = fftSize
        let halfN = n / 2
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        var windowed = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: halfN)
        var imag = [Float](repeating: 0, count: halfN)

        let frameCount = max(0, (samples.count - n) / hopSize + 1)
        var spectra: [[Float]] = []
        spectra.reserveCapacity(frameCount)

        samples.withUnsafeBufferPointer { samplePointer in
            for frame in 0..<frameCount {
                let offset = frame * hopSize
                vDSP_vmul(samplePointer.baseAddress! + offset, 1, window, 1, &windowed, 1, vDSP_Length(n))

                var magnitudes = [Float](repeating: 0, count: halfN)
                real.withUnsafeMutableBufferPointer { realPointer in
                    imag.withUnsafeMutableBufferPointer { imagPointer in
                        var split = DSPSplitComplex(
                            realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                        windowed.withUnsafeBufferPointer { windowedPointer in
                            windowedPointer.baseAddress!.withMemoryRebound(
                                to: DSPComplex.self, capacity: halfN) { complexPointer in
                                vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(halfN))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        // Bin 0 packs DC (real) and Nyquist (imag); drop Nyquist
                        // so it doesn't pollute the DC magnitude.
                        split.imagp[0] = 0
                        vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfN))
                    }
                }
                var count = Int32(halfN)
                magnitudes.withUnsafeMutableBufferPointer { pointer in
                    vvsqrtf(pointer.baseAddress!, pointer.baseAddress!, &count)
                }
                spectra.append(magnitudes)
            }
        }
        return spectra
    }

    // MARK: - Onset envelope (spectral flux)

    static func onsetEnvelope(_ spectra: [[Float]]) -> [Float] {
        guard spectra.count > 1 else { return [] }
        let binCount = spectra[0].count
        var difference = [Float](repeating: 0, count: binCount)
        var flux = [Float](repeating: 0, count: spectra.count)
        var zero: Float = 0

        for frame in 1..<spectra.count {
            var sum: Float = 0
            difference.withUnsafeMutableBufferPointer { pointer in
                let base = pointer.baseAddress!
                vDSP_vsub(spectra[frame - 1], 1, spectra[frame], 1, base, 1, vDSP_Length(binCount))
                // Half-wave rectify: only energy increases mark onsets.
                vDSP_vthres(base, 1, &zero, base, 1, vDSP_Length(binCount))
                vDSP_sve(base, 1, &sum, vDSP_Length(binCount))
            }
            flux[frame] = sum
        }

        // Whiten: subtract a local moving average, rectify again.
        let halfWindow = 8
        var prefix = [Double](repeating: 0, count: flux.count + 1)
        for index in 0..<flux.count {
            prefix[index + 1] = prefix[index] + Double(flux[index])
        }
        var whitened = [Float](repeating: 0, count: flux.count)
        for index in 0..<flux.count {
            let low = max(0, index - halfWindow)
            let high = min(flux.count - 1, index + halfWindow)
            let mean = (prefix[high + 1] - prefix[low]) / Double(high - low + 1)
            whitened[index] = max(0, flux[index] - Float(mean))
        }
        return whitened
    }

    // MARK: - BPM

    static func estimateBPM(_ envelope: [Float], frameRate: Double) -> Double {
        guard envelope.count > 64 else { return 0 }

        let maxLag = min(envelope.count - 1, 256)
        var acf = [Float](repeating: 0, count: maxLag + 1)
        envelope.withUnsafeBufferPointer { pointer in
            let base = pointer.baseAddress!
            for lag in 0...maxLag {
                var dot: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &dot, vDSP_Length(envelope.count - lag))
                acf[lag] = dot
            }
        }
        let normalization = acf[0]
        guard normalization > 0 else { return 0 }
        for lag in 0...maxLag { acf[lag] /= normalization }

        func interpolatedACF(_ lag: Double) -> Double {
            guard lag >= 0, lag < Double(maxLag) else { return 0 }
            let lower = Int(lag)
            let fraction = lag - Double(lower)
            return Double(acf[lower]) * (1 - fraction) + Double(acf[lower + 1]) * fraction
        }

        /// Autocorrelation combined over the first three harmonics of the lag —
        /// a true beat period also correlates at 2x and 3x.
        func combScore(_ lag: Double) -> Double {
            var score = 0.0
            for harmonic in 1...3 where lag * Double(harmonic) <= Double(maxLag) {
                score += interpolatedACF(lag * Double(harmonic)) / Double(harmonic)
            }
            return score
        }

        func tempoPrior(_ bpm: Double) -> Double {
            let deviation = Foundation.log2(bpm / 120.0)
            return exp(-0.5 * deviation * deviation / (1.0 * 1.0))
        }

        let minLag = max(2, Int((frameRate * 60.0 / 200.0).rounded(.down)))   // 200 BPM
        let maxSearchLag = min(maxLag - 3, Int((frameRate * 60.0 / 60.0).rounded(.up))) // 60 BPM
        guard minLag < maxSearchLag else { return 0 }

        var bestLag = minLag
        var bestWeightedScore = -Double.infinity
        for lag in minLag...maxSearchLag {
            let bpm = frameRate * 60.0 / Double(lag)
            let weighted = combScore(Double(lag)) * tempoPrior(bpm)
            if weighted > bestWeightedScore {
                bestWeightedScore = weighted
                bestLag = lag
            }
        }

        // Parabolic refinement around the winning integer lag.
        var refinedLag = Double(bestLag)
        if bestLag > minLag && bestLag < maxSearchLag {
            let left = combScore(Double(bestLag - 1))
            let center = combScore(Double(bestLag))
            let right = combScore(Double(bestLag + 1))
            let denominator = left - 2 * center + right
            if abs(denominator) > 1e-9 {
                let delta = 0.5 * (left - right) / denominator
                if abs(delta) <= 1 { refinedLag += delta }
            }
        }

        var bpm = frameRate * 60.0 / refinedLag

        // Octave disambiguation: prefer the 70–180 window when the folded
        // tempo is also well supported by the autocorrelation.
        let baseScore = combScore(refinedLag)
        if bpm < 70, combScore(refinedLag / 2) >= 0.6 * baseScore {
            bpm *= 2
        } else if bpm > 180, combScore(refinedLag * 2) >= 0.6 * baseScore {
            bpm /= 2
        }

        let rounded = (bpm * 10).rounded() / 10
        let nearestInteger = rounded.rounded()
        return abs(rounded - nearestInteger) <= 0.2 ? nearestInteger : rounded
    }

    // MARK: - Chromagram

    /// Folds FFT bins between 55 Hz and 2 kHz into 12 pitch classes
    /// (index 0 = C), accumulating power across all frames.
    static func chromagram(_ spectra: [[Float]], sampleRate: Double) -> [Double] {
        var chroma = [Double](repeating: 0, count: 12)
        guard let first = spectra.first else { return chroma }

        let binWidth = sampleRate / Double(fftSize)
        let minBin = max(1, Int((55.0 / binWidth).rounded(.up)))
        let maxBin = min(first.count - 1, Int((2000.0 / binWidth).rounded(.down)))
        guard minBin < maxBin else { return chroma }

        // Precompute each bin's pitch class (MIDI 60 = C, so midi % 12 has C = 0).
        var binPitchClass = [Int](repeating: 0, count: maxBin + 1)
        for bin in minBin...maxBin {
            let frequency = Double(bin) * binWidth
            let midi = Int((69.0 + 12.0 * Foundation.log2(frequency / 440.0)).rounded())
            binPitchClass[bin] = ((midi % 12) + 12) % 12
        }

        for magnitudes in spectra {
            for bin in minBin...maxBin {
                let magnitude = Double(magnitudes[bin])
                chroma[binPitchClass[bin]] += magnitude * magnitude
            }
        }

        let norm = sqrt(chroma.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            for index in 0..<12 { chroma[index] /= norm }
        }
        return chroma
    }

    // MARK: - Key estimation (Krumhansl–Schmuckler)

    static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
    static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    static func estimateKey(_ chroma: [Double]) -> (name: String, confidence: Double) {
        guard chroma.count == 12, chroma.contains(where: { $0 > 0 }) else {
            return ("Unknown", 0)
        }

        var scores: [(name: String, correlation: Double)] = []
        for tonic in 0..<12 {
            for (profile, suffix) in [(majorProfile, "Major"), (minorProfile, "Minor")] {
                var rotated = [Double](repeating: 0, count: 12)
                for index in 0..<12 {
                    rotated[index] = profile[((index - tonic) % 12 + 12) % 12]
                }
                scores.append((
                    name: "\(noteNames[tonic]) \(suffix)",
                    correlation: pearson(chroma, rotated)))
            }
        }

        scores.sort { $0.correlation > $1.correlation }
        let best = scores[0]
        let runnerUp = scores[1]
        return (best.name, max(0, best.correlation - runnerUp.correlation))
    }

    private static func pearson(_ x: [Double], _ y: [Double]) -> Double {
        let count = Double(x.count)
        let meanX = x.reduce(0, +) / count
        let meanY = y.reduce(0, +) / count
        var numerator = 0.0
        var sumSquaresX = 0.0
        var sumSquaresY = 0.0
        for index in 0..<x.count {
            let deltaX = x[index] - meanX
            let deltaY = y[index] - meanY
            numerator += deltaX * deltaY
            sumSquaresX += deltaX * deltaX
            sumSquaresY += deltaY * deltaY
        }
        let denominator = sqrt(sumSquaresX * sumSquaresY)
        return denominator > 0 ? numerator / denominator : 0
    }
}
