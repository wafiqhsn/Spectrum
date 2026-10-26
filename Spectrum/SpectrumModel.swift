import SwiftUI
import CoreAudio

@MainActor
final class SpectrumModel: ObservableObject {
    @Published var processes: [SpotifyProcess] = []
    @Published var selected: AudioObjectID = 0
    @Published var demo = false
    @Published private(set) var enabled = false
    @Published var running = false
    private var presentationActive = true
    @Published var bands = [Float](repeating: 0, count: SpectrumFFT.bandCount)
    @Published var status = "Ready · not capturing audio"
    @Published var detail = "Open Spotify and play a track, then select an audio source."
    @Published var vuLevels = [Double](repeating: 0, count: 2)
    @Published var receivedSignal = false
    @Published var sampleRate: Double = 48000
    private var capture: AudioCapture?
    private var timer: Timer?
    private let fft = SpectrumFFT()
    private var began = Date()
    private var lastFrame: UInt64 = 0
    private var lastDelivery = Date()
    private var phase: Double = 0

    func refresh() {
        do {
            processes = try ProcessCatalog.spotify()
            if selected != 0 && !processes.contains(where: { $0.id == selected }) { selected = 0 }
            if processes.isEmpty { detail = "Spotify was not found. Play a track and refresh, or use Demo." }
        } catch { detail = error.localizedDescription }
    }
    func start() {
        enabled = true
        if presentationActive { resumeCapture() }
        else { suspendCapture() }
    }
    func setPresentationActive(_ active: Bool) {
        guard presentationActive != active else { return }
        presentationActive = active
        guard enabled else { return }
        if active { resumeCapture() } else { suspendCapture() }
    }
    private func resumeCapture() {
        guard !running else { return }
        receivedSignal = false
        began = Date()
        lastDelivery = began
        lastFrame = 0
        if demo {
            sampleRate = 48000
            status = "DEMO · synthetic signal"
            detail = "This graph is not Spotify audio. The demo signal uses the same FFT processing."
        } else {
            refresh()
            let ids = selected == 0 ? processes.map(\.id) : [selected]
            do {
                let engine = AudioCapture()
                try engine.start(processes: ids)
                capture = engine
                sampleRate = engine.sampleRate
                status = "Tap active · waiting for signal"
                detail = "If macOS requests System Audio Recording permission, choose Allow."
            } catch {
                enabled = false
                status = "Capture unavailable"
                detail = error.localizedDescription + " You can use Demo instead."
                return
            }
        }
        running = true
        // Menu tracking uses a different run-loop mode; keep audio and playback updates live.
        let updateTimer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        updateTimer.tolerance = 0.003
        timer = updateTimer
        RunLoop.main.add(updateTimer, forMode: .common)
        RunLoop.main.add(updateTimer, forMode: .eventTracking)
    }
    func stop() {
        enabled = false
        releaseCapture()
        status = "Stopped · not capturing audio"
    }
    private func suspendCapture() {
        releaseCapture()
        status = "Paused · visualizer not visible"
        detail = "Audio capture resumes automatically when a visualizer is visible."
    }
    private func releaseCapture() {
        timer?.invalidate()
        timer = nil
        capture?.stop()
        capture = nil
        running = false
        receivedSignal = false
        bands = Array(repeating: 0, count: SpectrumFFT.bandCount)
        vuLevels = [0, 0]
    }
    private func tick() {
        guard running else { return }
        var input: [Float]?
        var rightInput: [Float]?
        if demo {
            let frequency = 180 + 140 * (1 + sin(Date().timeIntervalSince(began) * 0.7))
            input = (0..<SpectrumFFT.size).map { index in
                let t = phase + Double(index) / sampleRate
                return Float(0.3 * sin(2 * .pi * frequency * t) + 0.1 * sin(2 * .pi * 2300 * t))
            }
            phase += Double(SpectrumFFT.size) / sampleRate
        } else if let snapshot = capture?.mailbox.snapshot(count: SpectrumFFT.size), snapshot.frames != lastFrame {
            lastFrame = snapshot.frames
            lastDelivery = Date()
            input = snapshot.samples
            rightInput = snapshot.rightSamples
            let signal = snapshot.samples.contains { abs($0) > 0.00001 }
            let nextStatus = signal ? "Signal received · Spotify process" : "Tap active · silent audio"
            if receivedSignal != signal { receivedSignal = signal }
            if status != nextStatus {
                status = nextStatus
                detail = signal ? "PCM data is being received from the selected process. It is not stored or transmitted." : "Received samples are silent. Check playback, the selected process, and audio permissions."
            }
        }
        if !demo && Date().timeIntervalSince(lastDelivery) > 4 && status != "No audio data received" {
            receivedSignal = false
            status = "No audio data received"
            detail = "Check Spotify playback and permissions. If Spotify or the output changes, Stop → Refresh → Start. Demo is available."
        }
        // Approximate VU ballistics from PCM RMS, with 0 VU referenced to -12 dBFS RMS.
        // Demo and mono sources use the same signal on both meters.
        func meter(_ samples: [Float]?) -> Double {
            guard let samples, !samples.isEmpty else { return 0 }
            let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
            return min(1, rms / pow(10, -12.0 / 20) / pow(10, 3.0 / 20))
        }
        let meterTargets = [meter(input), meter(rightInput ?? input)]
        vuLevels = zip(vuLevels, meterTargets).map { old, new in old + (new - old) * (new > old ? 0.22 : 0.10) }
        let target = input.map { fft.analyze($0, sampleRate: sampleRate) } ?? Array(repeating: 0, count: SpectrumFFT.bandCount)
        bands = zip(bands, target).map { old, new in old + (new - old) * (new > old ? 0.65 : 0.18) }
    }
    func privacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
