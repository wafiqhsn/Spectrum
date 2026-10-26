import Accelerate
import Foundation

/// 4096-point Hann-windowed complex FFT; peak magnitude in 64 logarithmic bands.
/// Display values are relative dBFS estimates, not calibrated sound-pressure levels.
final class SpectrumFFT {
    static let size = 4096
    static let bandCount = 64
    private let setup = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2))!
    private var window = [Float](repeating: 0, count: size)
    init() { vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM)) }
    deinit { vDSP_destroy_fftsetup(setup) }
    func analyze(_ samples: [Float], sampleRate: Double) -> [Float] {
        precondition(samples.count == Self.size)
        var real = zip(samples, window).map(*)
        var imaginary = [Float](repeating: 0, count: Self.size)
        var power = [Float](repeating: 0, count: Self.size / 2)
        real.withUnsafeMutableBufferPointer { r in
            imaginary.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, 12, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(power.count))
            }
        }
        let high = min(20000.0, sampleRate / 2)
        let scale = 2 / window.reduce(0, +)
        return (0..<Self.bandCount).map { band in
            let lowHz = 20 * pow(high / 20, Double(band) / Double(Self.bandCount))
            let highHz = 20 * pow(high / 20, Double(band + 1) / Double(Self.bandCount))
            let lo = min(power.count - 1, max(1, Int(lowHz * Double(Self.size) / sampleRate)))
            let hi = min(power.count, max(lo + 1, Int(ceil(highHz * Double(Self.size) / sampleRate))))
            let amplitude = sqrt(power[lo..<hi].max() ?? 0) * scale
            return min(1, max(0, (20 * log10(max(amplitude, 0.00001)) + 80) / 80))
        }
    }
}
