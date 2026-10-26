import Foundation
import CoreAudio

@main
struct SignalChecks {
    static func main() {
        let fft = SpectrumFFT()
        let silent = fft.analyze(Array(repeating: 0, count: SpectrumFFT.size), sampleRate: 48000)
        precondition(silent.allSatisfy { $0 == 0 }, "Silence must remain zero")
        for rate in [44100.0, 48000.0, 96000.0] {
            for hz in [100.0, 1000.0, 10000.0] {
                let samples = (0..<SpectrumFFT.size).map { Float(0.5 * sin(2 * .pi * hz * Double($0) / rate)) }
                let result = fft.analyze(samples, sampleRate: rate)
                let peak = result.indices.max(by: { result[$0] < result[$1] })!
                let expected = Int(log(hz / 20) / log(20000 / 20) * 64)
                precondition(abs(peak - expected) <= 2, "FFT peak in wrong frequency band")
                precondition(result.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
                precondition(result[peak] > 0.85, "Unexpected amplitude normalization")
            }
        }
        let mailbox = SampleMailbox()
        var interleaved: [Float] = [0.1, -0.1, 0.2, -0.2, 0.3, -0.3, 0.4, -0.4]
        interleaved.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            withUnsafePointer(to: &list) { mailbox.write($0) }
        }
        let snapshot = mailbox.snapshot(count: 4)!
        precondition(snapshot.samples == [0.1, 0.2, 0.3, 0.4])
        precondition(snapshot.rightSamples == [-0.1, -0.2, -0.3, -0.4])
        precondition(snapshot.frames == 4)
        precondition(mailbox.snapshot(count: 5) == nil)
        var mono: [Float] = [0.4, 0.2, 0, -0.2]
        mono.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            withUnsafePointer(to: &list) { mailbox.write($0) }
        }
        let monoSnapshot = mailbox.snapshot(count: 4)!
        precondition(monoSnapshot.samples == monoSnapshot.rightSamples)
        print("PASS: silence, FFT peak and amplitude at 3 sample rates, stereo channel extraction, frame count.")
    }
}
