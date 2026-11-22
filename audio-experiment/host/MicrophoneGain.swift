import Foundation

/// Stateless gain for the wire's signed PCM16 little-endian samples. Never retains audio.
enum MicrophoneGain {
    static let minimumGain = 1.0
    static let maximumGain = 6.0
    static let defaultGain = 2.0
    static let silenceDBFS = -120.0
    private static let limiterKnee = 0.85

    struct Result {
        let pcm: Data
        let inputDBFS: Double
        let outputDBFS: Double
        let inputPeak: Double
        let outputPeak: Double
        let limitedSampleCount: Int
        let sampleCount: Int
        let effectiveGain: Double
    }

    enum ProcessingError: Error {
        case oddByteCount
        case invalidGain
    }

    static func process(_ data: Data, gain: Double = defaultGain) throws -> Result {
        guard data.count.isMultiple(of: 2) else { throw ProcessingError.oddByteCount }
        guard gain.isFinite else { throw ProcessingError.invalidGain }
        let effectiveGain = min(maximumGain, max(minimumGain, gain))
        let sampleCount = data.count / 2
        var pcm = Data(count: data.count)
        var inputSquares = 0.0, outputSquares = 0.0
        var inputPeak = 0.0, outputPeak = 0.0
        var limitedSampleCount = 0

        data.withUnsafeBytes { inputRaw in
            pcm.withUnsafeMutableBytes { outputRaw in
                let input = inputRaw.bindMemory(to: UInt8.self)
                let output = outputRaw.bindMemory(to: UInt8.self)
                for offset in stride(from: 0, to: data.count, by: 2) {
                    let bits = UInt16(input[offset]) | UInt16(input[offset + 1]) << 8
                    let sample = Double(Int16(bitPattern: bits)) / 32768.0
                    let amplified = sample * effectiveGain
                    let magnitude = abs(amplified)
                    var limited = amplified
                    if magnitude > limiterKnee {
                        // Equal slope at the knee; approach full scale without clipping or wrapping.
                        let headroom = 1.0 - limiterKnee
                        let softened = limiterKnee + headroom * tanh((magnitude - limiterKnee) / headroom)
                        limited = amplified < 0 ? -softened : softened
                        limitedSampleCount += 1
                    }
                    let integer = Int16(min(32767.0, max(-32768.0, (limited * 32768.0).rounded())))
                    let outputBits = UInt16(bitPattern: integer)
                    output[offset] = UInt8(truncatingIfNeeded: outputBits)
                    output[offset + 1] = UInt8(truncatingIfNeeded: outputBits >> 8)
                    let quantized = Double(integer) / 32768.0
                    inputSquares += sample * sample
                    outputSquares += quantized * quantized
                    inputPeak = max(inputPeak, abs(sample))
                    outputPeak = max(outputPeak, abs(quantized))
                }
            }
        }
        return Result(pcm: pcm,
                      inputDBFS: dbfs(sumSquares: inputSquares, count: sampleCount),
                      outputDBFS: dbfs(sumSquares: outputSquares, count: sampleCount),
                      inputPeak: inputPeak, outputPeak: outputPeak,
                      limitedSampleCount: limitedSampleCount,
                      sampleCount: sampleCount, effectiveGain: effectiveGain)
    }

    private static func dbfs(sumSquares: Double, count: Int) -> Double {
        guard count > 0, sumSquares > 0 else { return silenceDBFS }
        return max(silenceDBFS, 10.0 * log10(sumSquares / Double(count)))
    }
}
