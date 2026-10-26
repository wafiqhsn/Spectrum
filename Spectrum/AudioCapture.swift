import Foundation
import CoreAudio
import AppKit

struct AudioFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw AudioFailure(message: "\(operation) failed (OSStatus \(status)). Check System Audio Recording permission, then try again.")
    }
}
func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
struct SpotifyProcess: Identifiable, Hashable {
    let id: AudioObjectID
    let pid: pid_t
    let bundle: String
    var title: String { "\(bundle) · PID \(pid)" }
}

enum ProcessCatalog {
    static func spotify() throws -> [SpotifyProcess] {
        var property = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        try check(AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size), "Reading processes")
        guard size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try ids.withUnsafeMutableBytes { bytes in
            try check(AudioObjectGetPropertyData(system, &property, 0, nil, &size, bytes.baseAddress!), "Reading process list")
        }
        return ids.compactMap { id in
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidProperty = address(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(id, &pidProperty, 0, nil, &pidSize, &pid) == noErr else { return nil }
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleProperty = address(kAudioProcessPropertyBundleID)
            guard AudioObjectGetPropertyData(id, &bundleProperty, 0, nil, &bundleSize, &bundle) == noErr else { return nil }
            guard let bundle else { return nil }
            let name = bundle.takeRetainedValue() as String
            guard name == "com.spotify.client" || name.hasPrefix("com.spotify.client.") else { return nil }
            return SpotifyProcess(id: id, pid: pid, bundle: name)
        }.sorted { $0.pid < $1.pid }
    }
}

/// Fixed storage. The audio callback only tries the lock: it never waits for the UI.
/// Contention drops a block, which is acceptable for a visualizer (not a recorder).
final class SampleMailbox {
    private let lock = NSLock()
    private let capacity = 8192
    private let storage = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    private let rightStorage = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    private var cursor = 0
    private var filled = 0
    private var frames: UInt64 = 0
    init() { storage.initialize(repeating: 0, count: capacity); rightStorage.initialize(repeating: 0, count: capacity) }
    deinit { storage.deinitialize(count: capacity); storage.deallocate(); rightStorage.deinitialize(count: capacity); rightStorage.deallocate() }

    func write(_ input: UnsafePointer<AudioBufferList>) {
        guard lock.try() else { return }
        defer { lock.unlock() }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let data = first.mData, first.mNumberChannels > 0 else { return }
        // Select channel 1 instead of summing stereo, avoiding antiphase cancellation.
        // Supports both planar and interleaved native Float32 PCM, validated at setup.
        let stride = Int(first.mNumberChannels)
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size / stride
        let samples = data.assumingMemoryBound(to: Float.self)
        let planarRight = stride == 1 && buffers.count > 1 ? buffers[1] : nil
        let rightPointer = planarRight?.mData?.assumingMemoryBound(to: Float.self)
        let rightCount = Int(planarRight?.mDataByteSize ?? 0) / MemoryLayout<Float>.size
        for frame in 0..<count {
            let value = samples[frame * stride]
            storage[cursor] = value.isFinite ? value : 0
            let right = stride > 1 ? samples[frame * stride + 1] : (frame < rightCount ? rightPointer?[frame] ?? value : value)
            rightStorage[cursor] = right.isFinite ? right : 0
            cursor = (cursor + 1) % capacity
        }
        frames &+= UInt64(count)
        filled = min(capacity, filled + count)
    }
    func snapshot(count: Int) -> (samples: [Float], rightSamples: [Float], frames: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        guard filled >= count else { return nil }
        let start = (cursor - count + capacity) % capacity
        return ((0..<count).map { storage[(start + $0) % capacity] }, (0..<count).map { rightStorage[(start + $0) % capacity] }, frames)
    }
}

final class AudioCapture {
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var proc: AudioDeviceIOProcID?
    let mailbox = SampleMailbox()
    private(set) var sampleRate: Double = 48000

    func start(processes: [AudioObjectID]) throws {
        stop()
        guard !processes.isEmpty else { throw AudioFailure(message: "No Spotify process found. Open Spotify, play a track, then refresh.") }
        do {
            let description = CATapDescription(stereoMixdownOfProcesses: processes)
            description.name = "Spectrum"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap), "Creating Process Tap")
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var property = address(kAudioTapPropertyFormat)
            try check(AudioObjectGetPropertyData(tap, &property, 0, nil, &size, &format), "Reading audio format")
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                  format.mBitsPerChannel == 32, format.mSampleRate > 0 else {
                throw AudioFailure(message: "The tap format is not supported native Float32 PCM. Use Demo or try another output device.")
            }
            sampleRate = format.mSampleRate
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Spectrum Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &device), "Creating aggregate device")
            let box = mailbox
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, input, _, _, _ in
                box.write(input)
            }, "Installing audio callback")
            try check(AudioDeviceStart(device, proc), "Starting audio")
        } catch {
            stop()
            throw error
        }
    }
    func stop() {
        if device != 0 {
            if let proc {
                AudioDeviceStop(device, proc)
                AudioDeviceDestroyIOProcID(device, proc)
            }
            AudioHardwareDestroyAggregateDevice(device)
        }
        proc = nil
        device = 0
        if tap != 0 { AudioHardwareDestroyProcessTap(tap) }
        tap = 0
    }
    deinit { stop() }
}
