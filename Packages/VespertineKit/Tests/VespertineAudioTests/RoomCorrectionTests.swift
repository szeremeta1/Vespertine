//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import CVespertineRT
import Foundation
import Testing
@testable import VespertineAudio

private func output(_ uid: String) -> OutputDevice {
    OutputDevice(id: 0, uid: uid, name: uid, manufacturer: "", modelUID: nil, transport: .usb, nominalSampleRate: 48_000,
                 capabilities: DeviceCapabilities(sampleRates: [48_000], physicalFormats: [], outputChannels: 2, supportsDoP: true),
                 hasHardwareVolume: false, isDefault: false)
}

private func sections(_ channel: NRTRoomChannel) -> [NRTBiquad] {
    var copy = channel
    return withUnsafeBytes(of: &copy.sections) { Array($0.bindMemory(to: NRTBiquad.self).prefix(Int(channel.count))) }
}

@Suite("Room correction")
struct RoomCorrectionTests {
    @Test("Reads REW's Equalizer APO export: a preamp, then each speaker's delay, level and filters")
    func perSpeakerAPO() throws {
        let text = """
        Preamp: -4 dB
        Channel: L
        Delay: 1.25 ms
        Filter 1: ON PK Fc 42 Hz Gain -9.5 dB Q 6.0
        Filter 2: ON PK Fc 87 Hz Gain -4 dB Q 3
        Channel: R
        Preamp: -1.5 dB
        Filter 1: ON PK Fc 45 Hz Gain -7 dB Q 5.2
        """
        let profile = try RoomProfile.parseAPO(text, name: "Living room")
        #expect(profile.name == "Living room" && profile.preampDB == -4 && profile.channels.count == 2)
        #expect(profile.channels[0].delayMs == 1.25 && profile.channels[0].levelDB == 0 && profile.channels[0].bands.count == 2)
        #expect(profile.channels[0].bands[0].frequency == 42 && profile.channels[0].bands[0].gainDB == -9.5 && profile.channels[0].bands[0].q == 6)
        #expect(profile.channels[1].delayMs == 0 && profile.channels[1].levelDB == -1.5 && profile.channels[1].bands.count == 1)
    }

    @Test("Filters before any Channel line correct every speaker; ALL, numbers and several names select channels")
    func sharedAndScoped() throws {
        let text = """
        Filter: ON HPQ Fc 20 Hz Q 0.7
        Channel: 1 2
        Filter: ON PK Fc 60 Hz Gain -3 dB Q 4
        Channel: C
        Filter: ON PK Fc 70 Hz Gain -2 dB Q 4
        Channel: ALL
        Delay: 0.5 ms
        """
        let profile = try RoomProfile.parseAPO(text, name: "x")
        #expect(profile.channels.count == 3)
        #expect(profile.channels.map(\.bands.count) == [2, 2, 2])   // the shared high-pass, then the speaker's own
        #expect(profile.channels.allSatisfy { $0.delayMs == 0.5 && $0.bands[0].kind == .highPass })
        #expect(profile.channels[2].bands[1].frequency == 70 && profile.channels[0].bands[1].frequency == 60)
    }

    @Test("A plain single-speaker file (no Channel lines) corrects left and right alike")
    func plainFile() throws {
        let profile = try RoomProfile.parseAPO("Preamp: -2 dB\nFilter 1: ON PK Fc 50 Hz Gain -6 dB Q 5", name: "x")
        #expect(profile.channels.count == 2 && profile.channels[0] == profile.channels[1] && profile.preampDB == -2)
    }

    @Test("Refuses what it can't apply instead of playing something else")
    func refusals() {
        #expect(throws: EQImportError.noFilters) { try RoomProfile.parseAPO("Preamp: -2 dB", name: "x") }
        #expect(throws: EQImportError.unsupportedChannel(line: 1, name: "XL")) { try RoomProfile.parseAPO("Channel: XL", name: "x") }
        #expect(throws: EQImportError.delayInSamples(line: 1)) { try RoomProfile.parseAPO("Delay: 40 samples", name: "x") }
        #expect(throws: EQImportError.unsupportedCommand(line: 2, command: "Copy")) {
            try RoomProfile.parseAPO("Filter: ON PK Fc 50 Hz Gain -6 dB Q 5\nCopy: L=R", name: "x")
        }
        #expect(throws: EQImportError.graphicEQ) { try RoomProfile.parseAPO("GraphicEQ: 20 -1; 30 -2", name: "x") }
        let many = (1...(RoomProfile.maxBands + 1)).map { "Filter \($0): ON PK Fc \(30 + $0) Hz Gain -1 dB Q 4" }.joined(separator: "\n")
        #expect(throws: EQImportError.tooManyRoomFilters(RoomProfile.maxBands + 1)) { try RoomProfile.parseAPO(many, name: "x") }
    }

    @Test("Export reads back the same profile")
    func roundTrip() throws {
        let profile = RoomProfile(name: "x", preampDB: -3, channels: [
            RoomChannelCorrection(delayMs: 1.5, levelDB: -1, bands: [EQBand(kind: .peak, frequency: 42, gainDB: -8, q: 6)]),
            RoomChannelCorrection(bands: [EQBand(kind: .peak, frequency: 55, gainDB: -5, q: 4), EQBand(kind: .lowShelf, frequency: 120, gainDB: -2, q: 0.7)]),
        ])
        let back = try RoomProfile.parseAPO(profile.apoText, name: "x")
        #expect(back.preampDB == -3 && back.channels.count == 2)
        #expect(back.channels[0].delayMs == 1.5 && back.channels[0].levelDB == -1)
        #expect(back.channels.map { $0.bands.map(\.kind) } == profile.channels.map { $0.bands.map(\.kind) })
        #expect(back.channels[1].bands[0].frequency == 55 && back.channels[1].bands[0].gainDB == -5)
    }

    @Test("What the I/O thread gets: delay in frames at the device's rate, preamp and level as one gain, rate-designed sections")
    func renderChannels() {
        let profile = RoomProfile(name: "x", preampDB: -6, channels: [
            RoomChannelCorrection(delayMs: 2, levelDB: 6, bands: [EQBand(kind: .peak, frequency: 40, gainDB: -10, q: 5)]),
            RoomChannelCorrection(),
        ])
        let at48 = profile.renderChannels(sampleRate: 48_000, channelCount: 3)
        #expect(at48.count == 3)
        #expect(at48[0].delayFrames == 96 && abs(at48[0].gain - 1) < 1e-9 && at48[0].count == 1)
        #expect(at48[1].delayFrames == 0 && abs(at48[1].gain - pow(10, -6.0 / 20)) < 1e-12 && at48[1].count == 0)
        #expect(abs(at48[2].gain - pow(10, -6.0 / 20)) < 1e-12)   // past the profile: the preamp only
        let at192 = profile.renderChannels(sampleRate: 192_000, channelCount: 2)
        #expect(at192[0].delayFrames == 384)
        #expect(sections(at192[0])[0].b1 != sections(at48[0])[0].b1)   // the same band, designed for each rate
        // Delays past what the I/O thread holds are clamped.
        let far = RoomProfile(name: "x", channels: [RoomChannelCorrection(delayMs: 1000)]).renderChannels(sampleRate: 768_000, channelCount: 1)
        #expect(far[0].delayFrames == 40 * 768)   // the longest delay a profile can have, 40 ms
    }

    @Test("The rendered result: each channel's own delay and filters, through the real I/O-thread code")
    func render() {
        let profile = RoomProfile(name: "x", channels: [RoomChannelCorrection(delayMs: 1), RoomChannelCorrection(levelDB: -6.020599913279624)])
        let ring = nrt_ring_create(4096, 2)!
        let context = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(context); nrt_ring_destroy(ring) }
        nrt_context_set_gain(context, 1, 32)
        let channels = profile.renderChannels(sampleRate: 48_000, channelCount: 2)
        channels.withUnsafeBufferPointer { nrt_context_set_room(context, $0.baseAddress, UInt32($0.count)) }
        var input = [Float](repeating: 0, count: 2 * 256)
        input[0] = 1; input[1] = 1
        _ = input.withUnsafeBufferPointer { nrt_ring_write(ring, $0.baseAddress!, 256) }
        var out = [Float](repeating: 0, count: 2 * 256)
        out.withUnsafeMutableBufferPointer { nrt_context_render_interleaved(context, $0.baseAddress!, 256, 2) }
        #expect(out[0] == 0 && out[2 * 48] == 1)          // left: the impulse 1 ms (48 frames) late
        #expect(abs(out[1] - 0.5) < 1e-6 && out[3] == 0)  // right: at once, at half level
    }

    @Test("Off, flat or missing: no correction, so playback can stay bit-perfect; on: a ROOM CORRECTION badge")
    func engineAndBadge() {
        var settings = EngineSettings()
        let dac = output("DAC")
        #expect(settings.roomCorrection(for: dac) == nil && !settings.convertsDSDForRoom(dac))
        settings.roomCorrections["DAC"] = RoomProfile(name: "Flat", channels: [RoomChannelCorrection()])
        #expect(settings.roomCorrection(for: dac) == nil)
        var profile = RoomProfile(name: "Room", channels: [RoomChannelCorrection(bands: [EQBand(frequency: 40, gainDB: -6, q: 5)])])
        settings.roomCorrections["DAC"] = profile
        #expect(settings.roomCorrection(for: dac)?.name == "Room" && settings.processesSamples(on: dac))
        #expect(settings.convertsDSDForRoom(dac))
        settings.roomNativeDSDDeviceUIDs = ["DAC"]
        #expect(!settings.convertsDSDForRoom(dac) && settings.roomCorrection(for: dac) != nil)
        profile.enabled = false
        settings.roomCorrections["DAC"] = profile
        #expect(settings.roomCorrection(for: dac) == nil && settings.roomCorrection(for: output("Other")) == nil)

        let source = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 48_000, bitDepth: 24, channels: 2)
        let device = DeviceCapabilities(sampleRates: [48_000], physicalFormats: [], outputChannels: 2, supportsDoP: false)
        var path = SignalPath(source: source, decoderName: "Test", plan: FormatPlanner.plan(source: source, device: device),
            applied: AppliedFormat(sampleRate: 48_000, physicalBitDepth: 24, physicalIsInteger: true, virtualChannels: 2, exclusive: true, bufferFrames: 512),
            deviceName: "DAC", deviceUID: "DAC", deviceProfile: DeviceProfile(kind: .usbDAC, tag: "USB", canBeBitPerfect: true, symbol: "x"), volume: .hardware)
        #expect(path.isBitPerfect)
        path.roomCorrection = "Room"
        #expect(!path.isBitPerfect && path.statusLine == "ROOM CORRECTION")
        path.equalizer = "HD 650"
        #expect(path.statusLine == "ROOM CORRECTION")
    }

    @Test("With room correction on, DSD is converted to PCM (said so), instead of going out as DoP uncorrected")
    func dsdBecomesPCM() {
        let dsd = SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: 2_822_400, bitDepth: 1, channels: 2)
        let formats = [PhysicalFormat(minRate: 44_100, maxRate: 384_000, bitDepth: 24, isInteger: true, isMixable: true, channels: 2)]
        let dac = DeviceCapabilities(sampleRates: [44_100, 88_200, 176_400, 352_800], physicalFormats: formats, outputChannels: 2, supportsDoP: true)
        #expect(FormatPlanner.plan(source: dsd, device: dac).mode == .dop)
        let corrected = FormatPlanner.plan(source: dsd, device: dac, dsdToPCMForRoom: true)
        #expect(corrected.mode == .pcm && corrected.dsdConvertedToPCM && corrected.reason.contains("Room correction"))
        // PCM sources plan exactly as before.
        let pcm = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 88_200, bitDepth: 24, channels: 2)
        #expect(FormatPlanner.plan(source: pcm, device: dac, dsdToPCMForRoom: true) == FormatPlanner.plan(source: pcm, device: dac))
    }

    @Test("The no-clipping preamp covers the loudest speaker's boost, level included")
    func preampForNoClipping() {
        let profile = RoomProfile(name: "x", channels: [
            RoomChannelCorrection(bands: [EQBand(frequency: 60, gainDB: 3, q: 4)]),
            RoomChannelCorrection(levelDB: 2, bands: [EQBand(frequency: 60, gainDB: 4, q: 4)]),
        ])
        #expect(abs(profile.preampForNoClipping() + 6) < 0.15)
        #expect(RoomProfile(name: "Cuts", channels: [RoomChannelCorrection(bands: [EQBand(frequency: 60, gainDB: -6, q: 4)])]).preampForNoClipping() == 0)
        #expect(abs(profile.responseDB(channel: 1, at: [60], sampleRate: 48_000)[0] - 6) < 0.05)
    }
    @Test func impulseResponsesImportAndKeepTheirGainAtEveryRate() throws {
        // A 48 kHz stereo filter: the left speaker's a unit impulse 10 samples in, the right's half as loud.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("room-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 1000))
            buffer.frameLength = 1000
            for i in 0..<1000 { buffer.floatChannelData![0][i] = i == 10 ? 1 : 0; buffer.floatChannelData![1][i] = i == 10 ? 0.5 : 0 }
            try f.write(from: buffer)
        }
        let impulses = try RoomImpulse.importFile(url)
        defer { impulses.forEach { $0.delete() } }
        #expect(impulses.count == 2 && impulses[0].frames == 11 && impulses[0].sampleRate == 48_000)   // trailing silence trimmed
        let same = try #require(impulses[0].taps(at: 48_000))
        #expect(same.count == 11 && same[10] == 1)
        let doubled = try #require(impulses[1].taps(at: 96_000))
        #expect(abs(doubled.reduce(0, +) - 0.5) < 0.01)   // the same gain at twice the rate

        // In a profile: the speakers get their own filters, and a filter alone counts as correction.
        let profile = RoomProfile(name: "IR", channels: [RoomChannelCorrection(impulse: impulses[0]), RoomChannelCorrection(impulse: impulses[1])])
        #expect(!profile.isFlat)
        let taps = try #require(profile.impulseTaps(sampleRate: 48_000, channelCount: 3))
        #expect(taps.count == 3 && taps[0]?[10] == 1 && taps[1]?[10] == 0.5 && taps[2] == nil)
        #expect(profile.impulseKey(channelCount: 2) == [impulses[0].file, impulses[1].file])
        #expect(RoomProfile(name: "None").impulseTaps(sampleRate: 48_000, channelCount: 2) == nil)
        // A filter too long to run at a rate is left out there, and the signal path says so.
        let long = RoomImpulse(file: "none.f32", name: "Long", sampleRate: 48_000, frames: 200_000)
        #expect(long.fits(at: 48_000) && !long.fits(at: 96_000) && long.taps(at: 96_000) == nil)
        let longProfile = RoomProfile(name: "Long", channels: [RoomChannelCorrection(impulse: long)])
        #expect(!longProfile.filtersTooLong(sampleRate: 48_000, channelCount: 2) && longProfile.filtersTooLong(sampleRate: 96_000, channelCount: 2))
        #expect(!profile.filtersTooLong(sampleRate: 768_000, channelCount: 2))
        // A profile saved before filters existed still loads.
        let old = #"{"id":"6A1F2B9E-1C55-4C55-9A57-1F7A5E5B9D10","name":"Old","enabled":true,"preampDB":0,"channels":[{"delayMs":1,"levelDB":0,"bands":[]}]}"#
        let decoded = try JSONDecoder().decode(RoomProfile.self, from: Data(old.utf8))
        #expect(decoded.channels[0].impulse == nil && decoded.channels[0].delayMs == 1)
    }

    @Test func impulseResponsesThatArentAudioAreRefused() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("room-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("Filter 1: ON PK Fc 40 Hz Gain -6 dB Q 4".utf8).write(to: url)
        #expect(throws: RoomImpulseError.unreadable) { try RoomImpulse.importFile(url) }
    }
    @Test func measuringTwoSpeakersFindsTheirDelaysLevelsAndModes() throws {
        // A simulated take: the left speaker 100 samples away with a +10 dB mode at 50 Hz, the right 148 samples away
        // and quieter, both under a little noise.
        var plan = RoomMeasurementPlan(sampleRate: 48_000, speakers: 2)
        plan.sweepSeconds = 2
        plan.gapSeconds = 1.5
        let playback = plan.playback(levelDB: -12)
        let mode = try #require(EQBand(kind: .peak, frequency: 50, gainDB: 10, q: 5).section(sampleRate: 48_000))
        var left = playback[0].map(Double.init)
        var z1 = 0.0, z2 = 0.0
        for i in left.indices {
            let x = left[i], y = mode.b0 * x + z1
            z1 = mode.b1 * x - mode.a1 * y + z2
            z2 = mode.b2 * x - mode.a2 * y
            left[i] = y
        }
        var recording = [Float](repeating: 0, count: plan.frames + 48_000)
        for i in 0..<plan.frames {
            recording[i + 100] += Float(left[i] * 0.5)
            recording[i + 148] += playback[1][i] * 0.4
        }
        var seed: UInt32 = 7
        for i in recording.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            recording[i] += (Float(seed >> 8) / 16_777_216 - 0.5) * 1e-5
        }

        let speakers = try RoomMeasurement.analyze(recording: recording, plan: plan)
        #expect(speakers.count == 2)
        #expect(abs((speakers[1].arrivalMs - speakers[0].arrivalMs) - 1.0) < 0.01)              // 48 samples
        #expect(abs((speakers[1].levelDB - speakers[0].levelDB) - 20 * log10(0.4 / 0.5)) < 0.3)
        #expect(speakers.allSatisfy { $0.signalToNoiseDB > 40 })
        let cut = try #require(speakers[0].filters.first)
        #expect(abs(cut.frequency - 50) < 3 && abs(cut.gainDB + 10) < 2)
        #expect(speakers[1].filters.count <= 1)                                                   // flat already
        let i50 = RoomMeasurement.frequencies.firstIndex { $0 >= 50 }!
        #expect(abs(speakers[0].correctedDB[i50] - speakers[0].levelDB) < 2)

        // As a profile: the nearer left speaker held back 1 ms, the louder left one turned down to the right's level.
        let profile = RoomMeasurement.profile(speakers, name: "Living room")
        #expect(abs(profile.channels[0].delayMs - 1.0) < 0.01 && profile.channels[1].delayMs == 0)
        #expect(abs(profile.channels[0].levelDB - 20 * log10(0.4 / 0.5)) < 0.3 && profile.channels[1].levelDB == 0)
        #expect(profile.preampDB <= 0)
    }

    @Test func aSilentOrClippedMeasurementIsRefused() {
        let plan = RoomMeasurementPlan(sampleRate: 48_000, speakers: 2)
        #expect(throws: RoomMeasurementError.noSignal) { try RoomMeasurement.analyze(recording: [Float](repeating: 0, count: plan.frames), plan: plan) }
        #expect(throws: RoomMeasurementError.clipped) {
            try RoomMeasurement.analyze(recording: [Float](repeating: 1, count: plan.frames), plan: plan)
        }
    }
}
