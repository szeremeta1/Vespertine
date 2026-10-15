//
// Vespertine — measuring a room: each speaker plays a sweep in turn while a microphone at the listening position records,
// all in one take; the recording gives each speaker's arrival time, level and response, and peaking filters that
// flatten its bass (vespertine_measure.c). The result is a room profile like an imported one.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import CVespertineRT
import Foundation

/// How a measurement plays: one sweep per speaker, one after another, with a pause between for the room to go quiet.
public struct RoomMeasurementPlan: Sendable, Hashable {
    public var sampleRate: Double
    public var speakers: Int
    public var sweepSeconds = 4.0
    public var gapSeconds = 2.0
    public var leadSeconds = 0.5

    public static let lowestFrequency = 10.0

    public init(sampleRate: Double = 48_000, speakers: Int = 2) {
        self.sampleRate = sampleRate
        self.speakers = max(1, min(speakers, RoomProfile.maxChannels))
    }

    public var highestFrequency: Double { min(20_000, sampleRate * 0.45) }
    var sweepFrames: Int { Int(sweepSeconds * sampleRate) }
    /// From one speaker's sweep to the next's.
    var offsetFrames: Int { sweepFrames + Int(gapSeconds * sampleRate) }
    var leadFrames: Int { Int(leadSeconds * sampleRate) }
    public var frames: Int { leadFrames + speakers * offsetFrames }
    public var seconds: Double { Double(frames) / sampleRate }

    public func sweep() -> [Float] {
        var out = [Float](repeating: 0, count: sweepFrames)
        out.withUnsafeMutableBufferPointer { nrt_sweep_generate($0.baseAddress!, $0.count, sampleRate, Self.lowestFrequency, highestFrequency, 0.05) }
        return out
    }

    /// What each speaker plays, at `levelDB` below full scale.
    public func playback(levelDB: Double = -12) -> [[Float]] {
        let sweep = sweep(), gain = Float(pow(10, min(levelDB, 0) / 20))
        return (0..<speakers).map { c in
            var channel = [Float](repeating: 0, count: frames)
            let start = leadFrames + c * offsetFrames
            for i in 0..<sweep.count { channel[start + i] = sweep[i] * gain }
            return channel
        }
    }
}

/// One speaker, measured.
public struct SpeakerMeasurement: Sendable, Hashable {
    /// When its direct sound reached the microphone, from the start of the recording, less its place in the take: only
    /// the differences between speakers mean anything.
    public var arrivalMs: Double
    /// Its level from 300 Hz to 1 kHz, above the room's modes, in dB (relative: microphones differ).
    public var levelDB: Double
    /// The response (1/12-octave smoothed) at `RoomMeasurement.frequencies`, in dB.
    public var responseDB: [Double]
    /// Filters that bring its bass to the target.
    public var filters: [EQBand]
    /// The response with the filters applied.
    public var correctedDB: [Double]
    /// How far its direct sound stands above the noise, in dB.
    public var signalToNoiseDB: Double
}

/// What the fit may do. The defaults correct the bass only, as most rooms need and as is safest.
public struct RoomFitOptions: Sendable, Hashable {
    public var low = 20.0
    public var high = 250.0
    public var maxBoostDB = 3.0
    public var maxCutDB = 15.0
    public var maxFilters = 10
    public init() {}
}

public enum RoomMeasurementError: LocalizedError, Equatable {
    case noSignal
    case clipped
    case tooQuiet(speaker: Int, signalToNoiseDB: Double)
    case failed

    public var errorDescription: String? {
        switch self {
        case .noSignal: String(localized: "The microphone recorded nothing. Check that it's connected, selected and allowed to record.")
        case .clipped: String(localized: "The recording clipped. Turn the volume or the microphone's gain down and measure again.")
        case .tooQuiet(let speaker, let snr):
            String(localized: "Speaker \(speaker + 1) was too quiet against the room's noise (\(Int(snr)) dB). Turn the volume up, or make the room quieter, and measure again.")
        case .failed: String(localized: "The measurement couldn't be analysed.")
        }
    }
}

public enum RoomMeasurement {
    /// Where responses are given: 20 Hz to 20 kHz, 1/24 octave apart.
    public static let frequencies: [Double] = (0..<240).map { 20 * pow(2, Double($0) / 24) }

    /// The least a speaker's direct sound may stand above the noise.
    static let minimumSignalToNoiseDB = 30.0

    /// Analyses a recording (one microphone channel) of `plan`'s playback.
    public static func analyze(recording: [Float], plan: RoomMeasurementPlan, options: RoomFitOptions = .init()) throws -> [SpeakerMeasurement] {
        let loudest = recording.lazy.map { abs($0) }.max() ?? 0
        guard loudest > 1e-4 else { throw RoomMeasurementError.noSignal }
        guard recording.lazy.filter({ abs($0) >= 0.999 }).count < 8 else { throw RoomMeasurementError.clipped }
        let rate = plan.sampleRate
        let sweep = plan.sweep()
        var impulse = [Float](repeating: 0, count: recording.count)
        let ok = recording.withUnsafeBufferPointer { r in
            sweep.withUnsafeBufferPointer { s in
                impulse.withUnsafeMutableBufferPointer { i in
                    nrt_measure_impulse(r.baseAddress!, r.count, s.baseAddress!, s.count, rate, RoomMeasurementPlan.lowestFrequency,
                                        plan.highestFrequency, i.baseAddress!, i.count)
                }
            }
        }
        guard ok else { throw RoomMeasurementError.failed }

        // The first speaker's direct sound is the loudest peak before the second sweep; each next one is a sweep later,
        // give or take how much farther it is (50 ms is 17 m).
        let near = Int(0.05 * rate)
        let pre = Int(0.005 * rate), length = Int(0.5 * rate)
        var found: [(at: Double, value: Float)] = []
        try impulse.withUnsafeBufferPointer { ir in
            let first = nrt_impulse_peak(ir.baseAddress!, 0, min(ir.count, plan.leadFrames + plan.offsetFrames), nil)
            for c in 0..<plan.speakers {
                let expected = Int(first) + c * plan.offsetFrames
                let from = max(0, expected - near), to = min(ir.count, expected + near + 1)
                guard to - from > 2 else { throw RoomMeasurementError.failed }
                var value: Float = 0
                let at = nrt_impulse_peak(ir.baseAddress!, from, to, &value)
                found.append((at, value))
            }
        }

        var speakers: [SpeakerMeasurement] = []
        for (c, peak) in found.enumerated() {
            let start = max(0, Int(peak.at) - pre)
            guard start + length <= impulse.count else { throw RoomMeasurementError.failed }
            // Noise: what the response holds well after the room has decayed, before the next speaker's sweep.
            let quietFrom = start + length + Int(0.2 * rate), quietTo = min(impulse.count, start + plan.offsetFrames - Int(1.0 * rate))
            let noise = quietTo <= quietFrom ? 0
                : (impulse[quietFrom..<quietTo].reduce(0) { $0 + Double($1) * Double($1) } / Double(quietTo - quietFrom)).squareRoot()
            let snr = noise > 0 ? 20 * log10(Double(peak.value) / noise) : 120
            guard snr >= minimumSignalToNoiseDB else { throw RoomMeasurementError.tooQuiet(speaker: c, signalToNoiseDB: snr) }
            // 500 ms from just before the direct sound, faded out over its second half: the room's modes, at a
            // resolution of a couple of hertz, without the tail's noise.
            var window = Array(impulse[start..<(start + length)])
            for i in (length / 2)..<length {
                window[i] *= Float(0.5 + 0.5 * cos(Double.pi * Double(i - length / 2) / Double(length / 2)))
            }
            var response = [Double](repeating: 0, count: frequencies.count)
            let responded = window.withUnsafeBufferPointer { w in
                frequencies.withUnsafeBufferPointer { f in
                    response.withUnsafeMutableBufferPointer { r in
                        nrt_response_db(w.baseAddress!, w.count, rate, f.baseAddress!, f.count, 1.0 / 12, r.baseAddress!)
                    }
                }
            }
            guard responded else { throw RoomMeasurementError.failed }
            let band = frequencies.indices.filter { frequencies[$0] >= 300 && frequencies[$0] <= 1000 }
            let level = band.map { response[$0] }.reduce(0, +) / Double(max(band.count, 1))
            let filters = fit(response, target: level, rate: rate, options: options)
            let peaks = filters.map { NRTPeakFilter(frequency: $0.frequency, gainDB: $0.gainDB, q: $0.q) }
            let corrected = frequencies.indices.map { i in
                response[i] + peaks.withUnsafeBufferPointer { nrt_peaks_db($0.baseAddress!, UInt32($0.count), frequencies[i], rate) }
            }
            speakers.append(SpeakerMeasurement(arrivalMs: (peak.at - Double(c * plan.offsetFrames)) / rate * 1000, levelDB: level,
                                               responseDB: response, filters: filters, correctedDB: corrected, signalToNoiseDB: snr))
        }
        return speakers
    }

    /// Peaking filters bringing `response` to a flat `target` over options.low…high.
    static func fit(_ response: [Double], target: Double, rate: Double, options: RoomFitOptions) -> [EQBand] {
        var limits = NRTFitLimits(low: options.low, high: options.high, maxBoostDB: options.maxBoostDB, maxCutDB: options.maxCutDB,
                                  minQ: 0.5, maxQ: 12, maxFilters: UInt32(min(options.maxFilters, RoomProfile.maxBands)), toleranceDB: 1)
        let targets = [Double](repeating: target, count: response.count)
        var out = [NRTPeakFilter](repeating: NRTPeakFilter(), count: Int(limits.maxFilters))
        let made = frequencies.withUnsafeBufferPointer { f in
            response.withUnsafeBufferPointer { r in
                targets.withUnsafeBufferPointer { t in
                    out.withUnsafeMutableBufferPointer { o in
                        nrt_fit_peaks(f.baseAddress!, r.baseAddress!, t.baseAddress!, f.count, rate, &limits, o.baseAddress!)
                    }
                }
            }
        }
        return out.prefix(Int(made)).map {
            EQBand(kind: .peak, frequency: ($0.frequency * 10).rounded() / 10, gainDB: ($0.gainDB * 10).rounded() / 10, q: ($0.q * 100).rounded() / 100)
        }
    }

    /// A room profile from a measurement: the nearer speakers held back to meet the farthest, the louder ones turned
    /// down to the quietest, each with its own filters, and a preamp so the filters' boosts can't clip.
    public static func profile(_ speakers: [SpeakerMeasurement], name: String) -> RoomProfile {
        let latest = speakers.map(\.arrivalMs).max() ?? 0
        let quietest = speakers.map(\.levelDB).min() ?? 0
        var profile = RoomProfile(name: name, channels: speakers.map { s in
            RoomChannelCorrection(delayMs: min(((latest - s.arrivalMs) * 1000).rounded() / 1000, RoomChannelCorrection.delayRange.upperBound),
                                  levelDB: max(((quietest - s.levelDB) * 10).rounded() / 10, RoomChannelCorrection.levelRange.lowerBound),
                                  bands: s.filters)
        })
        profile.preampDB = profile.preampForNoClipping()
        return profile
    }
}

// MARK: - Microphones

public struct AudioInput: Sendable, Hashable, Identifiable {
    public var id: AudioObjectID
    public var name: String
    public var uid: String
    /// A measurement microphone by name (UMIK, EMM-6, ECM8000 …): their calibration is close to flat.
    public var looksLikeMeasurementMic: Bool {
        let n = name.lowercased()
        return ["umik", "emm-6", "emm6", "ecm8000", "measurement", "minidsp", "dayton", "isemcon", "cmc"].contains { n.contains($0) }
    }

    /// Every device that can record.
    public static func all() -> [AudioInput] {
        let devices = (try? HAL.getArray(AudioObjectID(kAudioObjectSystemObject), .global(kAudioHardwarePropertyDevices), of: AudioObjectID.self)) ?? []
        return devices.compactMap { device in
            let streams = (try? HAL.getArray(device, .input(kAudioDevicePropertyStreams), of: AudioStreamID.self)) ?? []
            guard !streams.isEmpty else { return nil }
            return AudioInput(id: device, name: HAL.getString(device, .global(kAudioObjectPropertyName)) ?? "Input",
                              uid: HAL.getString(device, .global(kAudioDevicePropertyDeviceUID)) ?? "\(device)")
        }
    }
}

// MARK: - Running

/// Plays a measurement through an output with a separate engine, nothing else in the path, and records a microphone.
public final class RoomMeasurementRunner: @unchecked Sendable {
    public let output: OutputDevice
    public let input: AudioObjectID

    public init(output: OutputDevice, input: AudioObjectID) {
        self.output = output
        self.input = input
    }

    /// Plays `plan` at `levelDB` with `settings` (the player's own, so the volume is the listener's) less anything that
    /// changes the sound, and returns the microphone's first channel.
    public func record(_ plan: RoomMeasurementPlan, levelDB: Double, settings base: EngineSettings,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) throws -> [Float] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-measure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sweeps.wav")
        let playback = plan.playback(levelDB: levelDB)
        let samples: [[Int32]] = playback.map { channel in channel.map { Int32(($0 * 8_388_607).rounded()) } }
        try LoopbackWAV.write(samples, range: 0..<plan.frames, bits: 24, sampleRate: plan.sampleRate, to: url)

        var settings = base
        settings.deviceUID = output.uid
        settings.deviceName = output.name
        settings.ratePolicies[output.uid] = .matchSource
        settings.spatialModes[output.uid] = .off
        settings.equalizers = [:]
        settings.roomCorrections = [:]
        settings.bitstreamDeviceUIDs = []

        try? DeviceControl.setNominalRate(plan.sampleRate, on: input)
        let recorder = try LoopbackRecorder(device: input, rate: plan.sampleRate, maxChannels: 1)
        try recorder.start()
        defer { recorder.restore() }
        let engine = PlaybackEngine()
        engine.update(settings: settings)
        Thread.sleep(forTimeInterval: 0.2)
        recorder.drain()
        engine.play(PlayableItem(url: url))
        let started = Date()
        var played = false
        while Date().timeIntervalSince(started) < plan.seconds + 15 {
            Thread.sleep(forTimeInterval: 0.02)
            recorder.drain()
            let snap = engine.snapshot
            if snap.state == .playing { played = true }
            progress(min(1, Date().timeIntervalSince(started) / plan.seconds))
            if played, snap.state == .stopped { break }
            if !played, let error = snap.lastError, Date().timeIntervalSince(started) > 2 {
                engine.stopAndWait()
                recorder.stop()
                throw CoreAudioError(-1, error)
            }
        }
        // The last speaker's room, and the device's own latency, play out.
        let tailEnd = Date().addingTimeInterval(1.0)
        while Date() < tailEnd { Thread.sleep(forTimeInterval: 0.02); recorder.drain() }
        engine.stopAndWait()
        recorder.stop()
        return recorder.samples.first ?? []
    }
}
