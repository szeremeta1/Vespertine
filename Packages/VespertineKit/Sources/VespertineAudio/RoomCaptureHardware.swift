//
// Vespertine — the Core Audio side of room measurement capture: microphone permission, an input recorder and a
// one-shot player on explicitly chosen devices. Prototype: exercised against hardware by hand, not by the test suite.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import CoreAudio
import Foundation

/// Microphone access through AVCaptureDevice, which is what attaches the permission to the app (the prompt shows
/// NSMicrophoneUsageDescription).
public struct SystemMicrophonePermission: MicrophonePermission {
    public init() {}

    public var status: MicrophoneAccess {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    public func request() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }
}

/// Plays mono buffers on channels of an output device, once, all from the same frame. The IOProc only reads buffers
/// allocated before it starts and advances a position it alone writes: no allocation, locks or Objective-C on the audio
/// thread.
final class RoomStimulusPlayer: @unchecked Sendable {
    let device: AudioObjectID
    /// Every track's samples, one after another, `count` each.
    private let samples: UnsafeMutablePointer<Float>
    private let count: Int
    private let channels: [Int]
    private let position = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "org.szeremeta.vespertine.room-player", qos: .userInteractive)

    init(device: AudioObjectID, stimulus: RoomStimulus, rate: Double) throws {
        self.device = device
        channels = stimulus.tracks.map(\.channel)
        count = stimulus.tracks.map(\.samples.count).min() ?? 0
        let name = HAL.getString(device, .global(kAudioObjectPropertyName)) ?? "The output"
        let actual = (try? HAL.get(device, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0
        // Changing the device's rate would change the listener's setup, so the measurement refuses instead.
        guard abs(actual - rate) < 0.5 else { throw CoreAudioError(-1, "\(name) runs at \(Int(actual)) Hz, the measurement needs \(Int(rate)) Hz; set it in Audio MIDI Setup. Output") }
        let configured = try Self.channelCount(device)
        let highest = channels.max() ?? 0
        guard highest < configured else { throw CoreAudioError(-1, "\(name) has \(configured) output channels, not \(highest + 1). Output") }
        samples = .allocate(capacity: max(1, count * channels.count))
        for (t, track) in stimulus.tracks.enumerated() {
            (samples + t * count).initialize(from: track.samples, count: count)
        }
        position.initialize(to: 0)
    }

    deinit {
        stop()
        samples.deallocate()
        position.deallocate()
    }

    static func channelCount(_ device: AudioObjectID) throws -> Int {
        var address = AudioObjectPropertyAddress.output(kAudioDevicePropertyStreamConfiguration)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "output stream configuration size")
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw), "output stream configuration")
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    func start() throws {
        let samples = samples, count = count, channels = channels
        position.pointee = 0
        let position = position
        var id: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&id, device, queue) { _, _, _, outputData, _ in
            let list = UnsafeMutableAudioBufferListPointer(outputData)
            var firstChannel = 0
            for buffer in list {
                let width = Int(buffer.mNumberChannels)
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), width > 0 else { continue }
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * width)
                memset(buffer.mData, 0, Int(buffer.mDataByteSize))
                for (t, channel) in channels.enumerated() where channel >= firstChannel && channel < firstChannel + width {
                    let column = channel - firstChannel, track = samples + t * count
                    for f in 0..<frames {
                        let p = position.pointee + f
                        if p < count { data[f * width + column] = track[p] }
                    }
                }
                firstChannel += width
            }
            position.pointee += list.first.map { Int($0.mDataByteSize) / (MemoryLayout<Float>.size * max(1, Int($0.mNumberChannels))) } ?? 0
        }, "AudioDeviceCreateIOProcIDWithBlock (output)")
        procID = id
        try check(AudioDeviceStart(device, id), "AudioDeviceStart (output)")
    }

    func stop() {
        guard let procID else { return }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        self.procID = nil
    }
}

/// Records one input channel with the existing capture ring and plays the stimulus on its output channels.
public final class CoreAudioRoomDevice: RoomCaptureDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: LoopbackRecorder?
    private var player: RoomStimulusPlayer?
    private var channel = 0
    private var cursor = 0
    private var seenDiscontinuities = 0
    private var devices: [AudioObjectID] = []

    public init() {}

    public func start(request: RoomCaptureRequest, stimulus: RoomStimulus) throws {
        lock.lock(); defer { lock.unlock() }
        stopLocked()
        let rate = request.layout.sampleRate
        let recorder = try LoopbackRecorder(device: request.inputDevice, rate: rate)
        guard request.inputChannel < recorder.channels else {
            throw CoreAudioError(-1, "The input has \(recorder.channels) channels, not \(request.inputChannel + 1). Input")
        }
        let player = try RoomStimulusPlayer(device: request.outputDevice, stimulus: stimulus, rate: rate)
        self.recorder = recorder
        self.player = player
        channel = request.inputChannel
        cursor = 0
        seenDiscontinuities = 0
        devices = [request.inputDevice, request.outputDevice]
        try recorder.start()
        try player.start()
    }

    public func readAvailable(maxFrames: Int) -> RoomCaptureChunk {
        lock.lock(); defer { lock.unlock() }
        guard let recorder else { return RoomCaptureChunk(frames: [], lostFrames: 0, alive: false) }
        let alive = devices.allSatisfy { ((try? HAL.get($0, .global(kAudioDevicePropertyDeviceIsAlive), initial: UInt32(0))) ?? 0) != 0 }
        recorder.drain()
        let all = recorder.samples[channel]
        let take = min(maxFrames, all.count - cursor)
        let frames = take > 0 ? Array(all[cursor..<cursor + take]) : []
        cursor += take
        let discontinuities = recorder.discontinuityCount
        let lost = discontinuities - seenDiscontinuities
        seenDiscontinuities = discontinuities
        return RoomCaptureChunk(frames: frames, lostFrames: lost > 0 ? lost : 0, alive: alive)
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        player?.stop()
        player = nil
        recorder?.stop()
        recorder?.restore()
        recorder = nil
    }
}

// MARK: - Finding the devices

public struct RoomAudioDevice: Sendable, Equatable {
    public let id: UInt32
    public let name: String
    public let uid: String
    /// Channels in the scope asked for (input channels for an input device, output channels for an output).
    public let channels: Int
    public let nominalRate: Double

    public init(id: UInt32, name: String, uid: String, channels: Int, nominalRate: Double) {
        self.id = id
        self.name = name
        self.uid = uid
        self.channels = channels
        self.nominalRate = nominalRate
    }
}

/// Looks devices up by name or as the system default. Read-only: nothing is changed on any device.
public enum RoomDeviceDirectory {
    private static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func describe(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> RoomAudioDevice? {
        guard let name = HAL.getString(id, .global(kAudioObjectPropertyName)) else { return nil }
        let uid = HAL.getString(id, .global(kAudioDevicePropertyDeviceUID)) ?? ""
        let rate = (try? HAL.get(id, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0
        return RoomAudioDevice(id: id, name: name, uid: uid, channels: channelCount(id, scope: scope), nominalRate: rate)
    }

    /// The first input device whose name contains `fragment` (case-insensitive).
    public static func inputDevice(named fragment: String) -> RoomAudioDevice? {
        for id in DeviceQuery.allDeviceIDs() {
            if let d = describe(id, scope: kAudioObjectPropertyScopeInput), d.channels > 0,
               d.name.range(of: fragment, options: .caseInsensitive) != nil { return d }
        }
        return nil
    }

    /// The output device with `uid`, if it is connected and has output channels.
    public static func output(uid: String) -> RoomAudioDevice? {
        for id in DeviceQuery.allDeviceIDs() {
            if let d = describe(id, scope: kAudioObjectPropertyScopeOutput), d.channels > 0, d.uid == uid { return d }
        }
        return nil
    }

    public static func defaultOutput() -> RoomAudioDevice? {
        DeviceQuery.defaultOutputDeviceID().flatMap { describe($0, scope: kAudioObjectPropertyScopeOutput) }
    }
}

// MARK: - A stand-in room

/// A scripted room for trying the measurement without a microphone or a speaker: the stimulus through a delay, a
/// gain, a bass resonance and a treble roll-off, with a little noise. Delivers at once rather than in real time.
public final class SimulatedRoomDevice: RoomCaptureDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var recording: [Float] = []
    private var cursor = 0
    public var gain: [Int: Double] = [0: 0.05, 1: 0.04]
    public var delaySeconds: [Int: Double] = [0: 0.0081, 1: 0.0094]

    public init() {}

    public func start(request: RoomCaptureRequest, stimulus: RoomStimulus) throws {
        let frames = request.layout.recordingFrames
        var out = [Double](repeating: 0, count: frames)
        for track in stimulus.tracks {
            let heard = speaker(track.channel, playing: track.samples, rate: request.layout.sampleRate, frames: frames)
            for n in 0..<frames { out[n] += heard[n] }
        }
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        let recorded = out.map { v -> Float in
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Float(v + (Double(seed >> 11) / Double(1 << 53) - 0.5) * 2e-5)
        }
        lock.withLock { recording = recorded; cursor = 0 }
    }

    /// What the microphone hears of output `channel` playing `samples`: a delay, a gain, a room mode (a peaking filter,
    /// RBJ cookbook) and a one-pole treble roll-off.
    private func speaker(_ channel: Int, playing samples: [Float], rate: Double, frames: Int) -> [Double] {
        let g = gain[channel] ?? 0.04
        let shift = Int(((delaySeconds[channel] ?? 0.009) * rate).rounded())
        let f0 = channel == 0 ? 63.0 : 71.0, q = 3.0, boost = 7.0
        let a: Double = pow(10, boost / 40), w: Double = 2 * Double.pi * f0 / rate
        let alpha: Double = sin(w) / (2 * q), cw: Double = cos(w)
        let b0: Double = 1 + alpha * a, b1: Double = -2 * cw, b2: Double = 1 - alpha * a
        let a0: Double = 1 + alpha / a, a1: Double = -2 * cw, a2: Double = 1 - alpha / a
        let lp: Double = exp(-2 * Double.pi * 7_000 / rate)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0, l = 0.0
        var out = [Double](repeating: 0, count: frames)
        for n in 0..<frames {
            let x: Double = n - shift >= 0 && n - shift < samples.count ? Double(samples[n - shift]) : 0
            let feed: Double = b0 * x + b1 * x1 + b2 * x2
            let y: Double = (feed - a1 * y1 - a2 * y2) / a0
            x2 = x1; x1 = x; y2 = y1; y1 = y
            l = (1 - lp) * y + lp * l
            out[n] = g * l
        }
        return out
    }

    public func readAvailable(maxFrames: Int) -> RoomCaptureChunk {
        lock.withLock {
            let take = min(maxFrames, 9_600, recording.count - cursor)
            defer { cursor += max(0, take) }
            return RoomCaptureChunk(frames: take > 0 ? Array(recording[cursor..<cursor + take]) : [], lostFrames: 0, alive: true)
        }
    }

    public func stop() {}
}

/// Granted without asking: for the simulated room.
public struct AlwaysGrantedMicrophone: MicrophonePermission {
    public init() {}
    public var status: MicrophoneAccess { .granted }
    public func request() async -> Bool { true }
}
