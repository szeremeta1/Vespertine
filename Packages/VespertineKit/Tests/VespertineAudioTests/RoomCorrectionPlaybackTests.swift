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
    RoomCorrectionPlayback(profileID: UUID(), name: "Desk", preampDB: preampDB, channels: [left, right])
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
    let ring = nrt_ring_create(16_384, channels)!
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
    guard let c else { nrt_context_set_room(context, nil, nil, 0, 1); return }
    let bank = c.bank(sampleRate: rate)
    bank.sections.withUnsafeBufferPointer { s in
        bank.counts.withUnsafeBufferPointer { n in
            nrt_context_set_room(context, s.baseAddress, n.baseAddress, UInt32(bank.counts.count), bank.preamp)
        }
    }
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
            #expect(c.bank(sampleRate: rate).counts == [1, 0])
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

    @Test("Room correction applies to stereo PCM only: other channel counts bypass it")
    func stereoOnly() {
        let c = correction(left: [EQBand(kind: .peak, frequency: 120, gainDB: -10, q: 4)], right: [])
        #expect(c.applies(channels: 2))
        #expect(!c.applies(channels: 1) && !c.applies(channels: 6))
    }
}
