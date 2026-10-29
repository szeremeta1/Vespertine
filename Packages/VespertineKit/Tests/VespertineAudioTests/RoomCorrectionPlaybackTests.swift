//
// Vespertine — room correction in playback: separate filters per output channel on the I/O thread, off unless chosen,
// never on DoP, bitstream or integer samples, and named in the signal path.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CVespertineRT
import Foundation
import Testing
@testable import VespertineAudio

private func output(_ uid: String) -> OutputDevice {
    OutputDevice(id: 0, uid: uid, name: uid, manufacturer: "", modelUID: nil, transport: .usb, nominalSampleRate: 48_000,
                 capabilities: DeviceCapabilities(sampleRates: [48_000], physicalFormats: [], outputChannels: 2, supportsDoP: true),
                 hasHardwareVolume: false, isDefault: false)
}

private func correction(left: [EQBand], right: [EQBand], preampDB: Double = 0) -> RoomCorrectionPlayback {
    RoomCorrectionPlayback(profileID: UUID(), name: "Desk", preampDB: preampDB, bands: [left, right])
}

private func sections(_ channel: NRTRoomChannel) -> [NRTBiquad] {
    var copy = channel
    return withUnsafeBytes(of: &copy.sections) { Array($0.bindMemory(to: NRTBiquad.self).prefix(Int(channel.count))) }
}

/// Stereo tone: `fl` Hz on the left, `fr` Hz on the right, 0.25 peak.
private func stereoTone(_ fl: Double, _ fr: Double, frames: Int) -> [Float] {
    (0..<frames).flatMap { i -> [Float] in
        let t = Double(i) / 48_000
        return [Float(0.25 * sin(2 * Double.pi * fl * t)), Float(0.25 * sin(2 * Double.pi * fr * t))]
    }
}

private func render(_ input: [Float], channels: UInt32 = 2, setUp: (OpaquePointer) -> Void) -> [Float] {
    let frames = UInt32(input.count) / channels
    let ring = nrt_ring_create(UInt32(max(16_384, 2 * Int(frames))), channels)!
    let context = nrt_context_create(ring, 512)!
    defer { nrt_context_destroy(context); nrt_ring_destroy(ring) }
    nrt_context_set_gain(context, 1, 32)
    setUp(context)
    #expect(nrt_ring_write(ring, input, frames) == frames)
    var out = [Float](repeating: 0, count: input.count)
    nrt_context_render_interleaved(context, &out, frames, channels)
    return out
}

private func install(_ c: RoomCorrectionPlayback?, on context: OpaquePointer, rate: Double = 48_000) {
    RoomCorrectionPlayback.install(c, on: context, sampleRate: rate, channelCount: 2)
}

private func settledPeak(_ out: [Float], channel: Int) -> Float {
    stride(from: 4096 * 2 + channel, to: out.count, by: 2).map { abs(out[$0]) }.max() ?? 0
}

@Suite("Room correction in playback")
struct RoomCorrectionPlaybackTests {
    @Test("Left and right get their own filters: a cut on the left leaves the right channel bit-identical")
    func perChannel() {
        let c = correction(left: [EQBand(kind: .peak, frequency: 1_000, gainDB: -6.0206, q: 1)], right: [])
        let input = stereoTone(1_000, 1_000, frames: 8192)
        let out = render(input) { install(c, on: $0) }
        #expect(abs(settledPeak(out, channel: 0) - 0.125) < 0.002)
        let right = stride(from: 1, to: out.count, by: 2).map { out[$0] }
        let rightIn = stride(from: 1, to: input.count, by: 2).map { input[$0] }
        #expect(right == rightIn)
    }

    @Test("Distinct filters per channel don't bleed: each channel's tone is cut only by its own band")
    func noBleed() {
        let c = correction(left: [EQBand(kind: .peak, frequency: 500, gainDB: -12, q: 2)],
                           right: [EQBand(kind: .peak, frequency: 2_000, gainDB: -12, q: 2)])
        // Left plays 2 kHz (its band is at 500 Hz), right plays 500 Hz (its band is at 2 kHz): both nearly untouched.
        let out = render(stereoTone(2_000, 500, frames: 8192)) { install(c, on: $0) }
        #expect(abs(settledPeak(out, channel: 0) - 0.25) < 0.01)
        #expect(abs(settledPeak(out, channel: 1) - 0.25) < 0.01)
    }

    @Test("Off means off: removed, the samples go through untouched again")
    func offIsTransparent() {
        let c = correction(left: [EQBand(kind: .peak, frequency: 1_000, gainDB: -6, q: 1)], right: [], preampDB: -1)
        let input = stereoTone(1_000, 700, frames: 8192)
        let out = render(input) { context in
            install(c, on: context)
            install(nil, on: context)
        }
        #expect(out == input)
    }

    @Test("The preamp applies to every channel, so the balance holds")
    func preampAllChannels() {
        let c = correction(left: [], right: [], preampDB: -6.0206)
        let out = render(stereoTone(1_000, 1_000, frames: 8192)) { install(c, on: $0) }
        #expect(abs(settledPeak(out, channel: 0) - 0.125) < 0.001 && abs(settledPeak(out, channel: 1) - 0.125) < 0.001)
    }

    @Test("Room correction and the equalizer compose: both cuts land")
    func composesWithEqualizer() {
        let c = correction(left: [EQBand(kind: .peak, frequency: 1_000, gainDB: -6.0206, q: 1)], right: [])
        let eq = EQPreset(name: "EQ", bands: [EQBand(kind: .peak, frequency: 1_000, gainDB: -6.0206, q: 1)])
        let out = render(stereoTone(1_000, 1_000, frames: 8192)) { context in
            install(c, on: context)
            eq.sections(sampleRate: 48_000).withUnsafeBufferPointer { nrt_context_set_eq(context, $0.baseAddress, UInt32($0.count), 1) }
        }
        #expect(abs(settledPeak(out, channel: 0) - 0.0625) < 0.002)
        #expect(abs(settledPeak(out, channel: 1) - 0.125) < 0.002)
    }

    @Test("Never on passthrough (DoP) or integer samples")
    func bypassedOnPassthroughAndInteger() {
        let c = correction(left: [EQBand(kind: .peak, frequency: 1_000, gainDB: -12, q: 1)],
                           right: [EQBand(kind: .peak, frequency: 1_000, gainDB: -12, q: 1)], preampDB: -3)
        let input = stereoTone(1_000, 1_000, frames: 4096)
        #expect(render(input) { context in nrt_context_set_passthrough(context, true); install(c, on: context) } == input)
        #expect(render(input) { context in nrt_context_set_integer(context, true); install(c, on: context) } == input)
    }

    @Test("Coefficients are built for the actual rate: the band's centre stays put at 44.1, 48 and 96 kHz")
    func ratesRebuild() {
        let c = correction(left: [EQBand(kind: .peak, frequency: 120, gainDB: -10, q: 4)], right: [])
        for rate in [44_100.0, 48_000, 96_000] {
            #expect(abs(c.responseDB(channel: 0, at: [120], sampleRate: rate)[0] + 10) < 0.05)
            #expect(abs(c.responseDB(channel: 1, at: [120], sampleRate: rate)[0]) < 1e-9)
            #expect(c.renderChannels(sampleRate: rate, channelCount: 2).map(\.count) == [1, 0])
        }
    }

    @Test("Off by default; on only for the output it was measured on")
    func settingsPerDevice() {
        var s = EngineSettings()
        #expect(s.roomCorrection(for: output("zd3")) == nil)
        s.roomCorrections["zd3"] = correction(left: [EQBand(kind: .peak, frequency: 120, gainDB: -10, q: 4)], right: [])
        #expect(s.roomCorrection(for: output("zd3"))?.name == "Desk")
        #expect(s.roomCorrection(for: output("k11")) == nil)
        // One that changes nothing counts as none, so bit-perfect stays possible.
        s.roomCorrections["zd3"] = correction(left: [], right: [])
        #expect(s.roomCorrection(for: output("zd3")) == nil)
    }

    /// A path for `source` on an exclusive USB DAC, planned the way the engine plans it.
    private func path(for source: SourceFormat, dop: Bool) -> SignalPath {
        let plan = FormatPlanner.plan(source: source, device: DeviceCapabilities(sampleRates: [44_100, 48_000, 176_400, 352_800],
                                                                                 physicalFormats: [], outputChannels: 2, supportsDoP: dop))
        let applied = AppliedFormat(sampleRate: plan.deviceSampleRate, physicalBitDepth: 32, physicalIsInteger: true, virtualChannels: 2,
                                    exclusive: true, bufferFrames: 512)
        return SignalPath(source: source, decoderName: "test", plan: plan, applied: applied, deviceName: "DAC", deviceUID: "DAC",
                          deviceProfile: DeviceProfile(kind: .usbDAC, tag: "USB", canBeBitPerfect: true, symbol: "x"), volume: .hardware)
    }

    @Test("The signal path says ROOM CORRECTION when it's on, and isn't bit-perfect; off, bit-perfect is possible again")
    func signalPath() {
        let flac = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 44_100, bitDepth: 16, channels: 2)
        var p = path(for: flac, dop: true)
        #expect(p.isBitPerfect)
        p.roomCorrection = "Desk"
        #expect(!p.isBitPerfect && p.modifiesSamples && p.statusLine == "ROOM CORRECTION")
        p.equalizer = "HD 650"
        #expect(p.statusLine == "ROOM CORRECTION")
        p.roomCorrection = nil
        #expect(p.statusLine == "EQUALIZER")
    }

    @Test("Native DSD over DoP stays bit-perfect with room correction chosen: it's bypassed with the reason")
    func dopBypass() {
        let dsd = SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: 2_822_400, bitDepth: 1, channels: 2)
        var p = path(for: dsd, dop: true)
        p.bypassedRoomCorrection = "Desk"
        #expect(p.roomCorrection == nil && p.isBitPerfect && p.equalizerBypass == .dopBypass)
    }

    @Test("A stereo profile applies to stereo only; a 5.1 profile to 5.1, and to stereo music through its front pair")
    func layouts() {
        let c = correction(left: [EQBand(kind: .peak, frequency: 120, gainDB: -10, q: 4)], right: [])
        #expect(c.applies(channels: 2))
        #expect(!c.applies(channels: 1) && !c.applies(channels: 6))
        let surround = RoomCorrectionPlayback(profileID: UUID(), name: "5.1", preampDB: 0, bands: Array(repeating: [], count: 6))
        #expect(surround.applies(channels: 6) && surround.applies(channels: 2))
        #expect(!surround.applies(channels: 1) && !surround.applies(channels: 8))
    }

    @Test("What the I/O thread gets: delay in frames at the device's rate, preamp and level as one gain, rate-designed sections")
    func renderChannels() {
        let c = RoomCorrectionPlayback(profileID: UUID(), name: "x", preampDB: -6, channels: [
            RoomChannelPlayback(delayMs: 2, levelDB: 6, bands: [EQBand(kind: .peak, frequency: 40, gainDB: -10, q: 5)]),
            RoomChannelPlayback(),
        ])
        let at48 = c.renderChannels(sampleRate: 48_000, channelCount: 3)
        #expect(at48.count == 3)
        #expect(at48[0].delayFrames == 96 && abs(at48[0].gain - 1) < 1e-9 && at48[0].count == 1)
        #expect(at48[1].delayFrames == 0 && abs(at48[1].gain - pow(10, -6.0 / 20)) < 1e-12 && at48[1].count == 0)
        #expect(abs(at48[2].gain - pow(10, -6.0 / 20)) < 1e-12)   // past the profile: the preamp only
        let at192 = c.renderChannels(sampleRate: 192_000, channelCount: 2)
        #expect(at192[0].delayFrames == 384)
        #expect(sections(at192[0])[0].b1 != sections(at48[0])[0].b1)   // the same band, designed for each rate
        // Delays past what a profile may hold are clamped to 40 ms.
        let far = RoomCorrectionPlayback(profileID: UUID(), name: "x", preampDB: 0, channels: [RoomChannelPlayback(delayMs: 1000)])
        #expect(far.renderChannels(sampleRate: 768_000, channelCount: 1)[0].delayFrames == 40 * 768)
        #expect(abs(far.maxDelaySeconds - 0.04) < 1e-12)
    }

    @Test("Each speaker's own delay and level, through the real I/O-thread code")
    func delayAndLevel() {
        let c = RoomCorrectionPlayback(profileID: UUID(), name: "x", preampDB: 0, channels: [
            RoomChannelPlayback(delayMs: 1), RoomChannelPlayback(levelDB: -6.020599913279624),
        ])
        var input = [Float](repeating: 0, count: 2 * 256)
        input[0] = 1; input[1] = 1
        let out = render(input) { install(c, on: $0) }
        #expect(out[0] == 0 && out[2 * 48] == 1)          // left: the impulse 1 ms (48 frames) late
        #expect(abs(out[1] - 0.5) < 1e-6 && out[3] == 0)  // right: at once, at half level
    }

    @Test("A profile's alignment and filters land on the outputs its channel map names")
    func profileAlignment() throws {
        var profile = RoomProfile.imported(name: "Desk", deviceUID: "zd3", layout: .stereo, source: .measured,
                                           filters: RoomFilterSet(version: 1, channels: [.right: [EQBand(frequency: 120, gainDB: -6, q: 4)]]))
        profile.alignment = [.left: RoomSpeakerAlignment(delayMs: 0.5, levelDB: -1.5)]
        let playback = RoomCorrectionPlayback(profile: profile)
        #expect(playback.channels[0] == RoomChannelPlayback(delayMs: 0.5, levelDB: -1.5))
        #expect(playback.channels[1].delayMs == 0 && playback.channels[1].bands.count == 1)
        #expect(!playback.isFlat)
        // Alignment alone is a correction too.
        var aligned = RoomProfile.imported(name: "x", deviceUID: "zd3", layout: .stereo, source: .measured, filters: RoomFilterSet(version: 1, channels: [:]))
        #expect(RoomCorrectionPlayback(profile: aligned).isFlat)
        aligned.alignment = [.right: RoomSpeakerAlignment(delayMs: 0.2)]
        #expect(!RoomCorrectionPlayback(profile: aligned).isFlat)
        // Saved and read back, alignment and source survive.
        let back = try RoomCorrectionCoding.decodeProfile(RoomCorrectionCoding.encode(profile))
        #expect(back.alignment == profile.alignment && back.origin == .measured)
    }

    @Test("Speakers line up at the seat: the nearer ones wait for the farthest, the louder ones come down to the quietest")
    func alignmentRule() {
        let a = RoomSpeakerAlignment.align(arrivalMs: [.left: 3.0, .right: 4.25], levelDB: [.left: -40.0, .right: -42.5])
        #expect(a[.left] == RoomSpeakerAlignment(delayMs: 1.25, levelDB: -2.5))
        #expect(a[.right] == RoomSpeakerAlignment(delayMs: 0, levelDB: 0))
        // Never a boost, and never past what playback holds.
        let far = RoomSpeakerAlignment.align(arrivalMs: [.left: 0, .right: 90], levelDB: [.left: 0, .right: -50])
        #expect(far[.left]?.delayMs == 40 && far[.left]?.levelDB == -30 && far[.right]?.levelDB == 0)
    }

    @Test("Measured filters (impulse responses) play through the convolver, a block late, each on its own channel")
    func impulseFilters() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("room-ir-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A filter that is a pure gain of 0.5, 10 samples in.
        var taps = [Float](repeating: 0, count: 11)
        taps[10] = 0.5
        let impulse = RoomImpulse(file: "half.f32", name: "half", sampleRate: 48_000, frames: taps.count)
        try taps.withUnsafeBytes { try Data($0).write(to: folder.appendingPathComponent("half.f32")) }
        let c = RoomCorrectionPlayback(profileID: UUID(), name: "IR", preampDB: 0,
                                       channels: [RoomChannelPlayback(impulse: impulse), RoomChannelPlayback()], impulseDirectory: folder)
        #expect(!c.isFlat)
        let loaded = try #require(c.impulseTaps(sampleRate: 48_000, channelCount: 2))
        #expect(loaded.count == 2 && loaded[0] == taps && loaded[1] == nil)
        #expect(c.impulseKey(sampleRate: 48_000, channelCount: 2) != c.impulseKey(sampleRate: 96_000, channelCount: 2))
        // New filters take over within two 4,096-frame periods; the impulse comes after that.
        var input = [Float](repeating: 0, count: 2 * 12_000)
        let at = 9_500
        input[2 * at] = 1; input[2 * at + 1] = 1
        let out = render(input) { context in
            install(c, on: context)
            #expect(RoomCorrectionPlayback.installFilters(loaded, on: context))
        }
        let late = at + Int(NRT_FIR_BLOCK)
        #expect(abs(out[2 * (late + 10)] - 0.5) < 1e-6)          // left: through the filter
        #expect(out[2 * late + 1] == 1)                           // right: unfiltered, bit-exact, a block late too
        // Too long for a rate: left out there, and said so.
        let long = RoomImpulse(file: "none.f32", name: "Long", sampleRate: 48_000, frames: 200_000)
        let longPlayback = RoomCorrectionPlayback(profileID: UUID(), name: "Long", preampDB: 0, channels: [RoomChannelPlayback(impulse: long)])
        #expect(!longPlayback.filtersTooLong(sampleRate: 48_000, channelCount: 2) && longPlayback.filtersTooLong(sampleRate: 96_000, channelCount: 2))
    }

    @Test("With room correction on, DSD is converted to PCM (and says so), unless the output keeps native DSD")
    func dsdRule() {
        var s = EngineSettings()
        let zd3 = output("zd3")
        #expect(!s.convertsDSDForRoom(zd3))
        s.roomCorrections["zd3"] = correction(left: [EQBand(kind: .peak, frequency: 120, gainDB: -10, q: 4)], right: [])
        #expect(s.convertsDSDForRoom(zd3) && !s.convertsDSDForRoom(output("k11")))
        s.roomNativeDSDDeviceUIDs = ["zd3"]
        #expect(!s.convertsDSDForRoom(zd3) && s.roomCorrection(for: zd3) != nil)

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
}
