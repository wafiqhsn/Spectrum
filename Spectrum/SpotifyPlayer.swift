import AppKit
import CoreAudio
import SwiftUI

private struct SpotifySnapshot {
    let title: String
    let artist: String
    let album: String
    let playing: Bool
    let position: Double
    let duration: Double
    let volume: Double
    let shuffle: Bool
    let repeating: Bool
    let artworkURL: String
    let shuffleAvailable: Bool
    let repeatAvailable: Bool
}
private struct SpotifyScriptFailure: Error {
    let code: Int
    let message: String
}

@MainActor
final class SpotifyPlayer: ObservableObject {
    @Published private(set) var title = "Spotify"
    @Published private(set) var artist = "Connecting to Spotify…"
    @Published private(set) var album = ""
    @Published private(set) var artwork: NSImage?
    @Published private(set) var connected = false
    @Published private(set) var playing = false
    @Published private(set) var duration: Double = 1
    @Published var position: Double = 0
    @Published var volume: Double = 50
    @Published var volumeTarget = UserDefaults.standard.string(forKey: "volumeTarget") ?? "spotify" {
        didSet {
            UserDefaults.standard.set(volumeTarget, forKey: "volumeTarget")
            pendingVolume = nil; editingVolume = false
            volume = volumeTarget == "device" ? volume : spotifyVolume
            refreshDeviceVolume()
        }
    }
    @Published private(set) var deviceVolumeAvailable = false
    @Published private(set) var volumeError = ""
    private var spotifyVolume: Double = 50
    var volumeTargetTitle: String { volumeTarget == "device" ? "Device" : "Spotify" }
    var canAdjustVolume: Bool { volumeTarget == "device" ? deviceVolumeAvailable : (connected && !permissionDenied) }
    var volumeLabel: String { volumeTarget == "device" && !deviceVolumeAvailable ? "Device volume unavailable" : "\(volumeTargetTitle) \(Int(volume.rounded()))%" }

    @Published private(set) var shuffle = false
    @Published private(set) var repeating = false
    @Published private(set) var shuffleAvailable = false
    @Published private(set) var repeatAvailable = false
    @Published private(set) var error = ""
    @Published private(set) var permissionDenied = false
    var editingPosition = false
    var editingVolume = false
    private let queue = DispatchQueue(label: "dev.local.SpotifySpectrum.spotify")
    private var timer: Timer?
    private var presentationActive = true
    private var busy = false
    private var artworkAddress = ""
    private var artworkTask: URLSessionDataTask?
    private var artworkEnabled = true
    private var commandError = ""
    private var pendingVolume: Int?
    private var sendingVolume = false
    private var lastSentVolume: Int?

    func begin() {
        guard timer == nil else { return }
        refresh()
        schedulePolling()
    }
    func setPresentationActive(_ active: Bool) {
        guard presentationActive != active else { return }
        presentationActive = active
        guard timer != nil else { return }
        schedulePolling()
        if active { refresh() }
    }
    private func schedulePolling() {
        timer?.invalidate()
        // Continue playback controls while hidden, with less background polling.
        let updateTimer = Timer(timeInterval: presentationActive ? 1 : 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        updateTimer.tolerance = presentationActive ? 0.1 : 0.5
        timer = updateTimer
        RunLoop.main.add(updateTimer, forMode: .common)
        RunLoop.main.add(updateTimer, forMode: .eventTracking)
    }
    func end() {
        timer?.invalidate(); timer = nil
        artworkTask?.cancel(); artworkTask = nil
    }
    func retryConnection() {
        permissionDenied = false
        commandError = ""
        error = ""
        refresh()
    }
    func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") else {
            error = "Spotify desktop is not installed."
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
    func playPause() { command("playpause") }
    func next() { command("next track") }
    func previous() { command("previous track") }
    func toggleShuffle() { command("set shuffling to \(!shuffle)") }
    func toggleRepeat() { command("set repeating to \(!repeating)") }
    func seek() {
        guard position.isFinite else { return }
        position = min(max(0, position), duration)
        command("set player position to \(String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), position))")
    }
    private func refreshDeviceVolume() {
        guard volumeTarget == "device" else { volumeError = ""; return }
        guard let snapshot = OutputDeviceVolume.snapshot() else {
            deviceVolumeAvailable = false
            volumeError = "This output device does not support software volume. Use its own volume controls."
            return
        }
        deviceVolumeAvailable = true
        if !editingVolume { volume = snapshot.volume * 100 }
        volumeError = ""
    }
    func setVolume() {
        guard volume.isFinite else { return }
        if volumeTarget == "device" {
            volume = min(100, max(0, volume))
            guard let snapshot = OutputDeviceVolume.snapshot(), OutputDeviceVolume.set(volume / 100, using: snapshot) else {
                deviceVolumeAvailable = false; volumeError = "Unable to change this output device's volume. Check the device controls."
                return
            }
            deviceVolumeAvailable = true; volumeError = ""
            return
        }
        guard connected, !permissionDenied else { return }
        volume = min(100, max(0, volume))
        pendingVolume = Int(volume.rounded())
        drainVolume()
    }
    /// One request in flight, with only the newest drag value retained.
    /// Updates run during the gesture; release flushes the final value through the same path.
    private func drainVolume() {
        guard !sendingVolume else { return }
        guard connected, !permissionDenied, let value = pendingVolume else { pendingVolume = nil; return }
        pendingVolume = nil
        guard value != lastSentVolume else { return }
        sendingVolume = true
        commandError = ""; error = ""
        queue.async { [weak self] in
            let (_, failure) = Self.execute("set sound volume to \(value)")
            DispatchQueue.main.async {
                guard let self else { return }
                self.sendingVolume = false
                if let failure {
                    self.pendingVolume = nil; self.lastSentVolume = nil
                    self.handle(failure, fromCommand: true)
                    return
                }
                self.lastSentVolume = value
                if self.pendingVolume != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in self?.drainVolume() }
                } else if !self.editingVolume { self.refresh() }
            }
        }
    }
    func setArtworkEnabled(_ value: Bool) {
        artworkEnabled = value
        if !value {
            artworkTask?.cancel(); artworkTask = nil
            artworkAddress = ""; artwork = nil
        } else { refresh() }
    }

    private func command(_ body: String) {
        guard connected, !permissionDenied else { return }
        commandError = ""; error = ""
        // The body comes only from fixed commands or finite, clamped numeric values.
        queue.async { [weak self] in
            let (_, failure) = Self.execute(body)
            DispatchQueue.main.async {
                guard let self else { return }
                if let failure { self.handle(failure, fromCommand: true) }
                self.refresh()
            }
        }
    }
    func refresh() {
        refreshDeviceVolume()
        guard !busy, !permissionDenied else { return }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty else {
            connected = false; playing = false; duration = 1; position = 0
            title = "Spotify is not open"; artist = "Open Spotify to play music"; album = ""
            artwork = nil; artworkAddress = ""; artworkTask?.cancel()
            error = ""
            return
        }
        busy = true
        queue.async { [weak self] in
            let source = """
            set trackTitle to "No track selected"
            set trackArtist to "Select a track in Spotify"
            set trackAlbum to ""
            set trackDuration to 1000
            set trackArtwork to ""
            try
                set trackTitle to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set trackDuration to duration of current track
                set trackArtwork to artwork url of current track
            end try
            return {trackTitle, trackArtist, trackAlbum, player state as text, player position, trackDuration, sound volume, shuffling, repeating, trackArtwork, shuffling enabled, repeating enabled}
            """
            let (result, failure) = Self.execute(source)
            var snapshot: SpotifySnapshot?
            if let r = result, failure == nil, r.numberOfItems >= 12 {
                snapshot = SpotifySnapshot(
                    title: r.atIndex(1)?.stringValue ?? "Spotify", artist: r.atIndex(2)?.stringValue ?? "",
                    album: r.atIndex(3)?.stringValue ?? "", playing: r.atIndex(4)?.stringValue == "playing",
                    position: r.atIndex(5)?.doubleValue ?? 0,
                    duration: max(1, (r.atIndex(6)?.doubleValue ?? 1000) / 1000),
                    volume: r.atIndex(7)?.doubleValue ?? 50, shuffle: r.atIndex(8)?.booleanValue ?? false,
                    repeating: r.atIndex(9)?.booleanValue ?? false, artworkURL: r.atIndex(10)?.stringValue ?? "",
                    shuffleAvailable: r.atIndex(11)?.booleanValue ?? false,
                    repeatAvailable: r.atIndex(12)?.booleanValue ?? false)
            }
            let value = snapshot
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if let failure { self.handle(failure); return }
                guard let value else {
                    self.handle(SpotifyScriptFailure(code: 0, message: "Incomplete response from Spotify.")); return
                }
                self.connected = true; self.permissionDenied = false; self.error = self.commandError
                self.title = value.title; self.artist = value.artist; self.album = value.album
                self.playing = value.playing; self.duration = value.duration
                if !self.editingPosition { self.position = min(value.duration, max(0, value.position)) }
                self.spotifyVolume = min(100, max(0, value.volume))
                if !self.editingVolume && !self.sendingVolume && self.pendingVolume == nil {
                    if self.volumeTarget == "spotify" { self.volume = self.spotifyVolume }
                    self.lastSentVolume = Int(self.spotifyVolume.rounded())
                }
                self.shuffle = value.shuffle; self.repeating = value.repeating
                self.shuffleAvailable = value.shuffleAvailable; self.repeatAvailable = value.repeatAvailable
                self.loadArtwork(value.artworkURL)
            }
        }
    }
    private func handle(_ failure: SpotifyScriptFailure, fromCommand: Bool = false) {
        if failure.code == -1743 {
            permissionDenied = true; connected = false; playing = false
            artworkTask?.cancel(); artwork = nil; artworkAddress = ""
            title = "Allow Spotify control"; artist = "Settings → Spotify connection"; album = ""
            error = "Allow Spectrum → Spotify in System Settings → Privacy & Security → Automation, then click Reconnect."
        } else {
            if !fromCommand { connected = false; playing = false }
            error = "Spotify command failed (\(failure.code)). Try reconnecting; ads may limit playback controls."
            if fromCommand { commandError = error }
        }
    }
    nonisolated private static func execute(_ body: String) -> (NSAppleEventDescriptor?, SpotifyScriptFailure?) {
        let source = """
        with timeout of 3 seconds
            tell application id "com.spotify.client"
                \(body)
            end tell
        end timeout
        """
        guard let script = NSAppleScript(source: source) else {
            return (nil, SpotifyScriptFailure(code: 0, message: "Unable to create Spotify command."))
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            return (nil, SpotifyScriptFailure(code: error[NSAppleScript.errorNumber] as? Int ?? 0, message: error[NSAppleScript.errorMessage] as? String ?? "Command failed"))
        }
        return (result, nil)
    }
    private func loadArtwork(_ address: String) {
        guard artworkEnabled, address != artworkAddress else { return }
        artworkTask?.cancel(); artwork = nil; artworkAddress = address
        guard let url = URL(string: address), url.scheme == "https" else { return }
        artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            guard let data, data.count < 8_000_000, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            DispatchQueue.main.async {
                guard let self, self.artworkEnabled, self.artworkAddress == address else { return }
                self.artwork = NSImage(data: data)
            }
        }
        artworkTask?.resume()
    }
}


/// Uses the current default output. Hardware without writable scalar controls stays read-only.
private enum OutputDeviceVolume {
    struct Snapshot {
        let device: AudioObjectID
        let elements: [AudioObjectPropertyElement]
        let volume: Double
    }
    private static func address(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }
    static func snapshot() -> Snapshot? {
        var output = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &output, 0, nil, &size, &device) == noErr, device != kAudioObjectUnknown else { return nil }
        func read(_ element: AudioObjectPropertyElement) -> Double? {
            var property = address(element), writable = DarwinBoolean(false)
            guard AudioObjectHasProperty(device, &property), AudioObjectIsPropertySettable(device, &property, &writable) == noErr, writable.boolValue else { return nil }
            var value: Float32 = 0, bytes = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(device, &property, 0, nil, &bytes, &value) == noErr, value.isFinite else { return nil }
            return min(1, max(0, Double(value)))
        }
        if let value = read(kAudioObjectPropertyElementMain) {
            return Snapshot(device: device, elements: [kAudioObjectPropertyElementMain], volume: value)
        }
        var stereo = [UInt32](repeating: 0, count: 2)
        var preferred = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyPreferredChannelsForStereo, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var bytes = UInt32(MemoryLayout<UInt32>.size * 2)
        let result = stereo.withUnsafeMutableBytes { AudioObjectGetPropertyData(device, &preferred, 0, nil, &bytes, $0.baseAddress!) }
        let candidates: [UInt32] = result == noErr ? Array(Set(stereo.filter { $0 != 0 })).sorted() : [1, 2]
        let values = candidates.compactMap { channel -> (UInt32, Double)? in read(channel).map { (channel, $0) } }
        guard !values.isEmpty else { return nil }
        return Snapshot(device: device, elements: values.map { $0.0 }, volume: values.map { $0.1 }.reduce(0, +) / Double(values.count))
    }
    static func set(_ volume: Double, using snapshot: Snapshot) -> Bool {
        var success = true
        for element in snapshot.elements {
            var property = address(element)
            var value = Float32(min(1, max(0, volume)))
            if AudioObjectSetPropertyData(snapshot.device, &property, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) != noErr { success = false }
        }
        return success
    }
}
