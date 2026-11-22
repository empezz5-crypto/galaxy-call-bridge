import Foundation

@main
enum MicrophoneGainChecks {
    static func encode(_ samples: [Int16]) -> Data {
        Data(samples.flatMap { sample in
            let bits = UInt16(bitPattern: sample)
            return [UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8)]
        })
    }

    static func decode(_ data: Data) -> [Int16] {
        let bytes = Array(data)
        return stride(from: 0, to: bytes.count, by: 2).map {
            Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)
        }
    }

    static func approximately(_ value: Double, _ expected: Double, tolerance: Double = 0.000001) {
        precondition(abs(value - expected) < tolerance, "Expected \(expected), got \(value)")
    }

    static func main() throws {
        let silence = try MicrophoneGain.process(Data(repeating: 0, count: 640), gain: 6)
        precondition(silence.pcm == Data(repeating: 0, count: 640))
        precondition(silence.inputDBFS == -120 && silence.outputDBFS == -120)
        precondition(silence.inputPeak == 0 && silence.outputPeak == 0)
        precondition(silence.sampleCount == 320 && silence.limitedSampleCount == 0)

        let quiet = try MicrophoneGain.process(encode([1000, -1000, 2000, -2000]))
        precondition(decode(quiet.pcm) == [2000, -2000, 4000, -4000])
        precondition(quiet.effectiveGain == 2 && quiet.limitedSampleCount == 0)
        approximately(quiet.inputDBFS, 20 * log10(sqrt(2_500_000.0) / 32768.0))
        approximately(quiet.outputDBFS - quiet.inputDBFS, 20 * log10(2.0))
        approximately(quiet.inputPeak, 2000.0 / 32768.0)
        approximately(quiet.outputPeak, 4000.0 / 32768.0)

        let fullScale = try MicrophoneGain.process(encode([32767, -32768, 20000, -20000]), gain: 6)
        let fullScaleSamples = decode(fullScale.pcm)
        precondition(fullScaleSamples[0] > 32000 && fullScaleSamples[1] < -32000)
        precondition(fullScaleSamples[2] > 32000 && fullScaleSamples[3] < -32000)
        precondition(fullScale.limitedSampleCount == 4)
        precondition(fullScale.outputPeak <= 1 && fullScale.outputDBFS <= 0)

        let symmetric = try MicrophoneGain.process(encode([15000, -15000, 16000, -16000]), gain: 2)
        let symmetricSamples = decode(symmetric.pcm)
        precondition(symmetricSamples[0] == -symmetricSamples[1])
        precondition(symmetricSamples[2] == -symmetricSamples[3])
        precondition(symmetricSamples[0] > 27852 && symmetricSamples[0] < 30000)
        precondition(symmetricSamples[2] > symmetricSamples[0] && symmetricSamples[2] < 32000)

        let lowGain = try MicrophoneGain.process(encode([1000]), gain: -20)
        let highGain = try MicrophoneGain.process(encode([1000]), gain: 50)
        precondition(lowGain.effectiveGain == 1 && decode(lowGain.pcm) == [1000])
        precondition(highGain.effectiveGain == 6 && decode(highGain.pcm) == [6000])
        for invalidGain in [Double.nan, Double.infinity, -Double.infinity] {
            do {
                _ = try MicrophoneGain.process(encode([1]), gain: invalidGain)
                preconditionFailure("Nonfinite gain must fail")
            } catch MicrophoneGain.ProcessingError.invalidGain { }
        }
        do {
            _ = try MicrophoneGain.process(Data([1, 2, 3]))
            preconditionFailure("An incomplete PCM16 sample must fail")
        } catch MicrophoneGain.ProcessingError.oddByteCount { }

        let empty = try MicrophoneGain.process(Data())
        precondition(empty.pcm.isEmpty && empty.sampleCount == 0)
        precondition(empty.inputDBFS == -120 && empty.outputDBFS == -120)

        // Data slices may have nonzero indices; processing must use byte offsets safely.
        let slice = encode([4, 5, 6, 7]).dropFirst(2)
        let sliced = try MicrophoneGain.process(slice)
        precondition(decode(sliced.pcm) == [10, 12, 14])
        precondition(sliced.pcm.count == slice.count && sliced.sampleCount == 3)

        // The same sample has the same output after loud frames: there is no AGC pumping.
        let repeatedQuiet = try MicrophoneGain.process(encode([1000, -1000, 2000, -2000]))
        precondition(repeatedQuiet.pcm == quiet.pcm)
        print("PASS synthetic PCM16 microphone gain: silence, RMS/peak, limiter, symmetry, bounds, invalid payloads, sample length, stateless response")
    }
}
