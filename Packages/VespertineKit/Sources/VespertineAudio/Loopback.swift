//
// Vespertine — the loopback self-test: plays test signals through a separate engine, out to a virtual loopback
// device, records them back from its input and compares every sample.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A software-path check: it proves decoding, the engine and Core Audio output deliver the samples exactly, not that a
// DAC or any hardware does. Each case writes its signal to temporary WAV files so the real decoder runs, plays them
// through a PlaybackEngine of its own with everything that could change the samples turned off (the planner, hog mode
// and gapless joins work as in normal playback), and records the device's input with a real-time-safe IOProc
// (`nrt_capture_ioproc`). The analysis is `LoopbackAnalyzer`.
//

import AVFAudio
import CVespertineRT
import CoreAudio
import Foundation
import VespertineAnalysisCore

/// One thing the test plays.
public struct LoopbackCase: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        /// One file.
        case single
        /// The signal split across two files, joined gaplessly.
        case gapless
        /// A 16-bit file, then a 24-bit one.
        case sixteenThenTwentyFour
    }
    public var kind: Kind
    public var sampleRate: Double
    public var bits: Int
    public var matchSixteenBit: Bool
    public var integerMode: Bool

    public init(kind: Kind = .single, sampleRate: Double, bits: Int, matchSixteenBit: Bool = false, integerMode: Bool = false) {
        self.kind = kind
        self.sampleRate = sampleRate
        self.bits = bits
        self.matchSixteenBit = matchSixteenBit
        self.integerMode = integerMode
    }

    public var id: String { name }
    public var name: String {
        let rate = SampleRate.format(sampleRate) + " kHz"
        switch kind {
        case .gapless: return "Gapless pair, \(bits)-bit at \(rate)"
        case .sixteenThenTwentyFour: return "16-bit then 24-bit at \(rate)" + (matchSixteenBit ? ", 16-bit matched" : "")
        case .single:
            switch bits {
            case 16: return "16-bit \(matchSixteenBit ? "matched" : "padded") at \(rate)"
            case 32: return "32-bit\(integerMode ? " integer mode" : "") at \(rate)"
            default: return "\(bits)-bit at \(rate)"
            }
        }
    }
}

public enum LoopbackMode: String, Sendable, Codable, CaseIterable {
    /// About 10 s: two rates, 24- and 16-bit, one gapless pair.
    case quick
    /// About 1–2 min: every common rate the device has, 24-bit, 16-bit matched and padded, 32-bit integer, both pairs.
    case full

    public var payloadSeconds: Double { self == .quick ? 0.5 : 2 }
}

public enum LoopbackPlan {
    public static let commonRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    /// The cases to run on a device offering `rates`.
    public static func cases(rates deviceRates: [Double], mode: LoopbackMode) -> [LoopbackCase] {
        let rates = commonRates.filter { r in deviceRates.contains { abs($0 - r) < 0.5 } }
        guard let first = rates.first else { return [] }
        switch mode {
        case .quick:
            let two = [44_100.0, 96_000].filter { rates.contains($0) }
            let quick = two.isEmpty ? [first] : two
            return quick.map { LoopbackCase(sampleRate: $0, bits: 24) }
                + [LoopbackCase(sampleRate: quick[0], bits: 16), LoopbackCase(kind: .gapless, sampleRate: quick[0], bits: 24)]
        case .full:
            var cases: [LoopbackCase] = []
            for rate in rates {
                cases.append(LoopbackCase(sampleRate: rate, bits: 24))
                cases.append(LoopbackCase(sampleRate: rate, bits: 16))
                cases.append(LoopbackCase(sampleRate: rate, bits: 16, matchSixteenBit: true))
                cases.append(LoopbackCase(sampleRate: rate, bits: 32, integerMode: true))
            }
            cases.append(LoopbackCase(kind: .gapless, sampleRate: first, bits: 24))
            cases.append(LoopbackCase(kind: .sixteenThenTwentyFour, sampleRate: first, bits: 24))
            return cases
        }
    }
}

public struct LoopbackCaseResult: Sendable, Hashable, Codable, Identifiable {
    public enum Status: String, Sendable, Codable { case bitExact, failed, setupProblem, skipped }
    public var testCase: LoopbackCase
    public var status: Status
    /// "bit-exact", the first diagnosis, or why it was skipped.
    public var summary: String
    /// One per signal played (two for the 16 → 24 pair).
    public var analyses: [LoopbackResult] = []
    /// What the separate engine was set to.
    public var settings: [String: String] = [:]
    /// The device format the engine read back, and what its signal path said.
    public var deviceFormat: String?
    public var signalPath: String?
    public var sixteenBitNote: String?
    public var engineUnderruns = 0
    public var recorderDiscontinuities = 0
    public var id: String { testCase.id }

    public init(testCase: LoopbackCase, status: Status, summary: String, analyses: [LoopbackResult] = [], settings: [String: String] = [:],
                deviceFormat: String? = nil, signalPath: String? = nil, sixteenBitNote: String? = nil) {
        self.testCase = testCase
        self.status = status
        self.summary = summary
        self.analyses = analyses
        self.settings = settings
        self.deviceFormat = deviceFormat
        self.signalPath = signalPath
        self.sixteenBitNote = sixteenBitNote
    }
}

public struct LoopbackReport: Sendable, Hashable, Codable {
    /// How results are labelled everywhere: never as hardware or DAC proof.
    public static let label = "Loopback (software check)"
    public static let scope = "A software-path check: decoding, Vespertine's engine and the Core Audio output deliver every sample exactly, looped back through a virtual device. It says nothing about a DAC, a cable or any hardware."

    public var outputDevice: String
    public var outputUID: String
    public var inputDevice: String
    public var macOS: String
    public var appVersion: String
    public var date: Date
    public var mode: LoopbackMode
    public var cases: [LoopbackCaseResult]

    public init(outputDevice: String, outputUID: String, inputDevice: String, macOS: String, appVersion: String, date: Date,
                mode: LoopbackMode, cases: [LoopbackCaseResult]) {
        self.outputDevice = outputDevice
        self.outputUID = outputUID
        self.inputDevice = inputDevice
        self.macOS = macOS
        self.appVersion = appVersion
        self.date = date
        self.mode = mode
        self.cases = cases
    }

    public var status: LoopbackCaseResult.Status {
        let ran = cases.filter { $0.status != .skipped }
        if ran.isEmpty { return .skipped }
        if ran.contains(where: { $0.status == .setupProblem }) { return .setupProblem }
        return ran.allSatisfy { $0.status == .bitExact } ? .bitExact : .failed
    }
}

public enum LoopbackError: LocalizedError, Sendable {
    case notVirtual(String)
    case inUse(String)
    case noInput(String)
    case inputFormat(String)
    case permissionDenied

    public var errorDescription: String? {
        switch self {
        case .notVirtual(let name):
            return "\(name) is a real output. The loopback test plays full-scale noise, so it runs only on a virtual loopback device such as \u{201C}\(LoopbackGuard.deviceName)\u{201D}."
        case .inUse(let name):
            return "Another app is using \(name). The test leaves it alone; use a loopback device of its own (\u{201C}\(LoopbackGuard.deviceName)\u{201D})."
        case .noInput(let name): return "\(name) has no input to record from."
        case .inputFormat(let name): return "\(name)'s input can't be set to Float32 at the test's rate."
        case .permissionDenied:
            return "Vespertine isn't allowed to record audio input, so nothing can be recorded from the loopback device. Allow it in System Settings › Privacy & Security › Microphone."
        }
    }
}

public enum LoopbackGuard {
    /// The dedicated BlackHole build the test expects (other BlackHole devices may be in use for something else).
    public static let deviceName = "Vespertine Loopback"

    /// Why the test must not play to `device`; nil when it may. Full-scale noise is loud on real speakers.
    public static func refusal(_ device: OutputDevice) -> LoopbackError? {
        device.transport == .virtual ? nil : .notVirtual(device.name)
    }

    /// The dedicated loopback device, when it's installed.
    public static func dedicatedDevice(in devices: [OutputDevice]) -> OutputDevice? {
        devices.first { $0.name == deviceName && $0.transport == .virtual }
    }

    /// A device with an input whose name contains `name`, or whose UID is `name`.
    public static func inputDevice(matching name: String) -> AudioObjectID? {
        DeviceQuery.allDeviceIDs().first { id in
            let streams = (try? HAL.getArray(id, .input(kAudioDevicePropertyStreams), of: AudioStreamID.self)) ?? []
            guard !streams.isEmpty else { return false }
            return HAL.getString(id, .global(kAudioDevicePropertyDeviceUID)) == name
                || (HAL.getString(id, .global(kAudioObjectPropertyName)) ?? "").localizedCaseInsensitiveContains(name)
        }
    }

    /// Another process is playing to or recording from `device`.
    public static func inUseByOthers(_ device: AudioObjectID) -> Bool {
        if DeviceControl.otherProcessesPlaying(to: device) { return true }
        let me = getpid()
        let processes = (try? HAL.getArray(AudioObjectID(kAudioObjectSystemObject), .global(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)) ?? []
        for process in processes {
            guard let pid = try? HAL.get(process, .global(kAudioProcessPropertyPID), initial: pid_t(0)), pid != me,
                  (try? HAL.get(process, .global(kAudioProcessPropertyIsRunningInput), initial: UInt32(0))) == 1 else { continue }
            let devices = (try? HAL.getArray(process, .input(kAudioProcessPropertyDevices), of: AudioObjectID.self)) ?? []
            if devices.contains(device) { return true }
        }
        return false
    }
}

public enum LoopbackPermission {
    /// Asks for audio input when it hasn't been asked yet. Hardened runtime denies input silently without the
    /// `com.apple.security.device.audio-input` entitlement and an NSMicrophoneUsageDescription.
    public static func ensure() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }
}

extension AudioObjectPropertyAddress {
    static func input(_ selector: AudioObjectPropertySelector, element: UInt32 = kAudioObjectPropertyElementMain) -> Self {
        .init(mSelector: selector, mScope: kAudioObjectPropertyScopeInput, mElement: element)
    }
}

// MARK: - Recording

/// Records a device's input into memory: an input IOProc writes a lock-free ring, drained here.
final class LoopbackRecorder {
    let device: AudioObjectID
    let channels: Int
    private let ring: OpaquePointer
    private let capture: OpaquePointer
    private var procID: AudioDeviceIOProcID?
    private var interleaved: [Float]
    private(set) var samples: [[Float]]
    /// Input stream formats changed for the test, put back by `restore()`.
    private var changedFormats: [(AudioStreamID, AudioStreamBasicDescription)] = []

    init(device: AudioObjectID, rate: Double, maxChannels: Int = 8) throws {
        self.device = device
        let name = HAL.getString(device, .global(kAudioObjectPropertyName)) ?? "The input"
        let streams = (try? HAL.getArray(device, .input(kAudioDevicePropertyStreams), of: AudioStreamID.self)) ?? []
        guard !streams.isEmpty else { throw LoopbackError.noInput(name) }
        // The IOProc reads Float32: put each input stream on Float32 at the test's rate.
        var total = 0
        for stream in streams {
            guard var current = try? HAL.get(stream, .global(kAudioStreamPropertyVirtualFormat), initial: AudioStreamBasicDescription()) else {
                throw LoopbackError.inputFormat(name)
            }
            if !Self.isFloat32(current, rate: rate) {
                let available = (try? HAL.getArray(stream, .global(kAudioStreamPropertyAvailableVirtualFormats), of: AudioStreamRangedDescription.self)) ?? []
                guard var float = available.first(where: {
                    Self.isFloat32($0.mFormat, rate: nil) && $0.mFormat.mChannelsPerFrame == current.mChannelsPerFrame
                        && rate >= $0.mSampleRateRange.mMinimum - 0.5 && rate <= $0.mSampleRateRange.mMaximum + 0.5
                })?.mFormat else { throw LoopbackError.inputFormat(name) }
                float.mSampleRate = rate
                changedFormats.append((stream, current))
                do { try HAL.set(stream, .global(kAudioStreamPropertyVirtualFormat), float) } catch { throw LoopbackError.inputFormat(name) }
                current = float
            }
            total += Int(current.mChannelsPerFrame)
        }
        channels = max(1, min(total, maxChannels))
        let maxSlice = (try? HAL.get(device, .global(kAudioDevicePropertyBufferFrameSizeRange), initial: AudioValueRange()))
            .map { UInt32(min(max($0.mMaximum, 4096), 65_536)) } ?? 16_384
        guard let ring = nrt_ring_create(UInt32(max(rate, 44_100) * 4), UInt32(channels)) else { throw CoreAudioError(-1, "allocate capture ring") }
        guard let capture = nrt_capture_create(ring, maxSlice) else {
            nrt_ring_destroy(ring)
            throw CoreAudioError(-1, "allocate capture")
        }
        self.ring = ring
        self.capture = capture
        interleaved = [Float](repeating: 0, count: 8192 * channels)
        samples = Array(repeating: [], count: channels)
    }

    static func isFloat32(_ f: AudioStreamBasicDescription, rate: Double?) -> Bool {
        f.mFormatID == kAudioFormatLinearPCM && f.mFormatFlags & kAudioFormatFlagIsFloat != 0 && f.mBitsPerChannel == 32
            && f.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 && rate.map { abs(f.mSampleRate - $0) < 0.5 } ?? true
    }

    func start() throws {
        var id: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcID(device, nrt_capture_ioproc, UnsafeMutableRawPointer(capture), &id), "AudioDeviceCreateIOProcID (input)")
        procID = id
        try check(AudioDeviceStart(device, id), "AudioDeviceStart (input)")
    }

    /// Moves what's been recorded from the ring into `samples`. Call often enough that the ring (4 s) never fills.
    func drain() {
        interleaved.withUnsafeMutableBufferPointer { buffer in
            while true {
                let got = Int(nrt_ring_read(ring, buffer.baseAddress!, UInt32(buffer.count / channels)))
                if got == 0 { break }
                for c in 0..<channels {
                    samples[c].reserveCapacity(samples[c].count + got)
                    for f in 0..<got { samples[c].append(buffer[f * channels + c]) }
                }
            }
        }
    }

    /// Capture frames where the input's sample time jumped or the ring overflowed.
    var discontinuities: [Int] {
        let kept = Int(NRT_CAPTURE_MAX_EVENTS)
        var positions = [UInt64](repeating: 0, count: kept)
        let count = Int(nrt_capture_discontinuities(capture, &positions, UInt32(kept)))
        return positions.prefix(min(count, kept)).map { Int($0) }
    }
    var discontinuityCount: Int { Int(nrt_capture_discontinuities(capture, nil, 0)) }

    func stop() {
        if let procID {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
        }
        procID = nil
        drain()
    }

    func restore() {
        for (stream, format) in changedFormats { try? HAL.set(stream, .global(kAudioStreamPropertyVirtualFormat), format) }
        changedFormats = []
    }

    deinit {
        stop()
        restore()
        nrt_capture_destroy(capture)
        nrt_ring_destroy(ring)
    }
}

// MARK: - Test files

enum LoopbackWAV {
    /// Integer PCM WAV of `samples[c][range]`: plain PCM for 16-bit, WAVE_FORMAT_EXTENSIBLE for 24 and 32.
    static func write(_ samples: [[Int32]], range: Range<Int>, bits: Int, sampleRate: Double, to url: URL) throws {
        let channels = samples.count
        let bytes = bits / 8
        var data = Data(capacity: 80 + range.count * channels * bytes)
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        let extensible = bits > 16
        let fmtSize = extensible ? 40 : 16
        let dataSize = range.count * channels * bytes
        data.append(contentsOf: Array("RIFF".utf8)); u32(4 + (8 + fmtSize) + (8 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(fmtSize)
        u16(extensible ? 0xFFFE : 1); u16(channels); u32(Int(sampleRate)); u32(Int(sampleRate) * channels * bytes)
        u16(channels * bytes); u16(bits)
        if extensible {
            u16(22); u16(bits); u32(channels == 2 ? 3 : 0)
            data.append(contentsOf: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71] as [UInt8])
        }
        data.append(contentsOf: Array("data".utf8)); u32(dataSize)
        for f in range {
            for c in 0..<channels {
                let v = UInt32(bitPattern: samples[c][f])
                for b in 0..<bytes { data.append(UInt8(truncatingIfNeeded: v >> (8 * b))) }
            }
        }
        try data.write(to: url)
    }
}

// MARK: - Running

public final class LoopbackRunner: @unchecked Sendable {
    public let output: OutputDevice
    public let inputDevice: AudioObjectID
    private let directory: URL

    /// `input`: the device to record; nil records the output device's own input (BlackHole loops it there).
    public init(output: OutputDevice, input: AudioObjectID? = nil) throws {
        if let refusal = LoopbackGuard.refusal(output) { throw refusal }
        self.output = output
        inputDevice = input ?? output.id
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-loopback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// Runs `cases` one after the other, calling `progress` before each. Puts both devices back on the rate they had.
    public func run(_ cases: [LoopbackCase], mode: LoopbackMode, appVersion: String,
                    progress: (Int, LoopbackCase) -> Void = { _, _ in },
                    caseDone: (LoopbackCaseResult) -> Void = { _ in }) throws -> LoopbackReport {
        if LoopbackGuard.inUseByOthers(output.id) { throw LoopbackError.inUse(output.name) }
        let originalRates = Set([output.id, inputDevice]).map { ($0, (try? HAL.get($0, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0) }
        defer { for (device, rate) in originalRates where rate > 0 { try? DeviceControl.setNominalRate(rate, on: device) } }
        var results: [LoopbackCaseResult] = []
        for (i, c) in cases.enumerated() {
            progress(i, c)
            let r = runCase(c, mode: mode)
            caseDone(r)
            results.append(r)
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return LoopbackReport(outputDevice: output.name, outputUID: output.uid,
                              inputDevice: HAL.getString(inputDevice, .global(kAudioObjectPropertyName)) ?? output.name,
                              macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", appVersion: appVersion,
                              date: Date(), mode: mode, cases: results)
    }

    /// The settings every case forces: nothing that could change the samples, output matched to the source.
    func engineSettings(for c: LoopbackCase) -> EngineSettings {
        var s = EngineSettings()
        s.exclusive = true
        s.deviceUID = output.uid
        s.deviceName = output.name
        s.ratePolicies = [output.uid: .matchSource]
        s.digitalVolumeDB = nil
        s.preferHardwareVolume = false
        s.spatialModes = [output.uid: .off]
        s.bitstreamDeviceUIDs = []
        s.dopDeviceUIDs = []
        s.equalizers = [:]
        s.integerMode = c.integerMode
        s.matchSixteenBit = c.matchSixteenBit
        return s
    }

    static func describe(_ s: EngineSettings) -> [String: String] {
        ["Exclusive access": s.exclusive ? "on" : "off", "Rate": "match source", "Digital volume": "off", "Equalizer": "off",
         "ReplayGain": "off", "Spatial Audio": "off", "Bitstream": "off", "DoP": "off", "Downmix": "none (stereo to stereo)",
         "Integer mode": s.integerMode ? "on" : "off", "Match 16-bit sources": s.matchSixteenBit ? "on" : "off"]
    }

    func runCase(_ c: LoopbackCase, mode: LoopbackMode) -> LoopbackCaseResult {
        let settings = engineSettings(for: c)
        var result = LoopbackCaseResult(testCase: c, status: .skipped, summary: "", settings: Self.describe(settings))
        if c.integerMode, c.bits == 32,
           !output.capabilities.physicalFormats.contains(where: { $0.isInteger && !$0.isMixable && $0.bitDepth == 32 && $0.supports(rate: c.sampleRate) }) {
            result.summary = "Skipped: \(output.name) has no 32-bit integer format (integer mode needs one, and Float32 can't carry 32 bits)"
            return result
        }

        // The signals, as files.
        let payload = mode.payloadSeconds
        var signals: [LoopbackSignal] = []
        var files: [URL] = []
        do {
            switch c.kind {
            case .single, .gapless:
                let signal = LoopbackSignal(.init(sampleRate: c.sampleRate, bits: c.bits, payloadSeconds: payload))
                signals = [signal]
                let parts = c.kind == .gapless ? [0..<signal.splitFrame, signal.splitFrame..<signal.frames] : [0..<signal.frames]
                for (i, part) in parts.enumerated() {
                    let url = directory.appendingPathComponent("case-\(UUID().uuidString)-\(i).wav")
                    try LoopbackWAV.write(signal.samples, range: part, bits: c.bits, sampleRate: c.sampleRate, to: url)
                    files.append(url)
                }
            case .sixteenThenTwentyFour:
                signals = [LoopbackSignal(.init(sampleRate: c.sampleRate, bits: 16, payloadSeconds: payload, syncSet: 0)),
                           LoopbackSignal(.init(sampleRate: c.sampleRate, bits: 24, payloadSeconds: payload, syncSet: 1))]
                for (i, signal) in signals.enumerated() {
                    let url = directory.appendingPathComponent("case-\(UUID().uuidString)-\(i).wav")
                    try LoopbackWAV.write(signal.samples, range: 0..<signal.frames, bits: signal.spec.bits, sampleRate: c.sampleRate, to: url)
                    files.append(url)
                }
            }
        } catch {
            result.status = .setupProblem
            result.summary = "Test setup problem: couldn't write the test files (\(error.localizedDescription))"
            return result
        }
        defer { for f in files { try? FileManager.default.removeItem(at: f) } }

        // The device at the test's rate before recording starts, so the recording never sees it change.
        for device in Set([output.id, inputDevice]) { try? DeviceControl.setNominalRate(c.sampleRate, on: device) }
        let recorder: LoopbackRecorder
        do {
            recorder = try LoopbackRecorder(device: inputDevice, rate: c.sampleRate)
            try recorder.start()
        } catch {
            result.status = .setupProblem
            result.summary = "Test setup problem: " + error.localizedDescription
            return result
        }
        defer { recorder.restore() }

        let items = files.map { PlayableItem(url: $0) }
        let engine = PlaybackEngine()
        engine.update(settings: settings)
        engine.nextItemProvider = { finished in
            guard let i = items.firstIndex(where: { $0.id == finished.id }), i + 1 < items.count else { return nil }
            return items[i + 1]
        }
        Thread.sleep(forTimeInterval: 0.2)
        recorder.drain()
        engine.play(items[0])
        let expected = signals.reduce(0) { $0 + Double($1.frames) / c.sampleRate }
        let started = Date()
        var played = false
        var path: SignalPath?
        while Date().timeIntervalSince(started) < expected + 15 {
            Thread.sleep(forTimeInterval: 0.02)
            recorder.drain()
            let snap = engine.snapshot
            if snap.state == .playing { played = true }
            if path == nil, let p = snap.signalPath { path = p }
            if played, snap.state == .stopped { break }
            if !played, let error = snap.lastError, Date().timeIntervalSince(started) > 2 {
                result.status = .failed
                result.summary = "Playback failed: \(error)"
                break
            }
        }
        // Let the device's own latency play out.
        let tailEnd = Date().addingTimeInterval(0.4)
        while Date() < tailEnd { Thread.sleep(forTimeInterval: 0.02); recorder.drain() }
        result.engineUnderruns = engine.snapshot.underruns
        engine.stopAndWait()
        recorder.stop()
        result.recorderDiscontinuities = recorder.discontinuityCount
        if let path {
            result.deviceFormat = "\(path.applied.physicalIsInteger ? "int" : "float") \(path.applied.physicalBitDepth)-bit · \(SampleRate.format(path.applied.sampleRate)) kHz · \(path.applied.exclusive ? "exclusive" : "shared")\(path.applied.integerMode ? " · integer mode" : "")"
            result.signalPath = path.plan.reason
            result.sixteenBitNote = path.sixteenBitNote
        }
        if result.status == .failed { return result }

        // Trim to what was recorded, with a margin, and analyze each signal.
        let captured = recorder.samples
        let live = captured.map { ch in (ch.firstIndex { $0 != 0 }, ch.lastIndex { $0 != 0 }) }
        let first = live.compactMap(\.0).min(), last = live.compactMap(\.1).max()
        let lower = max(0, (first ?? 0) - 4096)
        let upper = min(captured.first?.count ?? 0, (last ?? 0) + 4096)
        let trimmed = first == nil ? captured : captured.map { Array($0[lower..<max(lower, upper)]) }
        let discontinuities = recorder.discontinuities.map { $0 - (first == nil ? 0 : lower) }
        result.analyses = signals.map { LoopbackAnalyzer.analyze(captured: trimmed, signal: $0, discontinuities: discontinuities) }
        let verdicts = result.analyses.map(\.verdict)
        if verdicts.contains(.setupProblem) {
            result.status = .setupProblem
        } else if verdicts.allSatisfy({ $0 == .bitExact }) {
            result.status = .bitExact
        } else {
            result.status = .failed
        }
        result.summary = result.analyses.first(where: { $0.verdict != .bitExact })?.summary ?? "bit-exact"
        if !played, result.status != .bitExact { result.summary += " (playback never started)" }
        return result
    }
}
