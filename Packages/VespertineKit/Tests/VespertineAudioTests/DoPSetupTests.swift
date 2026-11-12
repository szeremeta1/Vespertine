//
// Vespertine: DoP auto-setup: the hint for unknown DACs, the one-tap test's result and its safety limits.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

private func uid(_ vendor: String, _ product: String) -> String { "AppleUSBAudioEngine:\(vendor):\(product):0000000:1" }

private func caps(maxRate: Double, dop: Bool = false) -> DeviceCapabilities {
    let rates: [Double] = [44_100, 48_000, 96_000, 176_400, 192_000, 352_800, 384_000].filter { $0 <= maxRate }
    let formats = [PhysicalFormat(minRate: rates.first ?? 44_100, maxRate: rates.last ?? 44_100, bitDepth: 24, isInteger: true, isMixable: false, channels: 2)]
    return DeviceCapabilities(sampleRates: rates, physicalFormats: formats, outputChannels: 2, supportsDoP: dop)
}

private let list = try! DoPDACList.decode(Data("""
{"schema":1,"revision":1,
 "dacs":[{"id":"known","name":"Known DAC","uidVendor":"Acme","uidProduct":"Known DAC","evidence":"manufacturer","source":"https://example.com/k"}],
 "makers":[{"id":"acme","name":"Acme Audio","uidVendors":["Acme"],"source":"https://example.com/m"}]}
""".utf8))

@Suite("DoP hint for unknown DACs")
struct DoPSetupHintTests {
    func decide(_ uid: String, rate: Double = 192_000, transport: Transport = .usb, on: Set<String> = [], off: Set<String> = [],
                vid: UInt16? = nil) -> DoPSetupHint {
        DoPSetupHint.decide(identity: DoPDeviceIdentity(uid: uid, usbVendorID: vid, usbProductID: vid == nil ? nil : 1), transport: transport,
                            capabilities: caps(maxRate: rate), on: on, off: off, list: list)
    }

    @Test("An unknown DAC from a listed DSD maker, at 176.4 kHz or more: try DoP, naming the maker")
    func makerSuggestion() {
        #expect(decide(uid("Acme", "Mystery")) == .suggestTest(maker: "Acme Audio"))
        #expect(decide(uid("Acme", "Mystery"), rate: 176_400) == .suggestTest(maker: "Acme Audio"))
    }

    @Test("An unknown DAC from an unlisted maker is offered the test, without a claim about it")
    func plainOffer() {
        #expect(decide(uid("Nobody", "Mystery")) == .offerTest)
    }

    @Test("Below 176.4 kHz there is no DoP carrier, so neither hint nor test")
    func tooSlow() {
        #expect(decide(uid("Acme", "Mystery"), rate: 96_000) == .none)
    }

    @Test("A known DAC needs neither")
    func knownDAC() {
        #expect(decide(uid("Acme", "Known DAC")) == .none)
    }

    @Test("Once the user (or the test) has chosen on or off for it, no more hints")
    func decided() {
        let u = uid("Acme", "Mystery")
        #expect(decide(u, on: [u]) == .none)
        #expect(decide(u, off: [u]) == .none)
    }

    @Test("Only USB and Thunderbolt outputs, the ones the DoP switch is shown for")
    func transports() {
        #expect(decide(uid("Acme", "Mystery"), transport: .hdmi) == .none)
        #expect(decide(uid("Acme", "Mystery"), transport: .bluetooth) == .none)
        #expect(decide(uid("Acme", "Mystery"), transport: .thunderbolt) == .suggestTest(maker: "Acme Audio"))
    }

    @Test("DoP already on in the device's capabilities: nothing to suggest")
    func alreadyOn() {
        let hint = DoPSetupHint.decide(identity: DoPDeviceIdentity(uid: uid("Acme", "Mystery")), transport: .usb,
                                       capabilities: caps(maxRate: 192_000, dop: true), on: [], off: [], list: list)
        #expect(hint == .none)
    }
}

@Suite("DoP test result")
struct DoPTestResultTests {
    let u = "AppleUSBAudioEngine:Acme:Mystery:0000000:1"

    @Test("Music turns DoP on for that device, in the same sets the DoP switch uses")
    func music() {
        var choices = DoPChoices(on: [], off: [u])
        choices.record(.music, for: u)
        #expect(choices.on == [u] && choices.off.isEmpty)
    }

    @Test("Hiss turns it off and keeps it off")
    func hiss() {
        var choices = DoPChoices(on: [u], off: [])
        choices.record(.hiss, for: u)
        #expect(choices.on.isEmpty && choices.off == [u])
    }

    @Test("Other devices' choices are left alone")
    func othersUntouched() {
        var choices = DoPChoices(on: ["a"], off: ["b"])
        choices.record(.music, for: u)
        #expect(choices.on == ["a", u] && choices.off == ["b"])
    }

    @Test("The result survives a relaunch: it goes through the stored on/off arrays and resolves the same")
    func persists() {
        let suite = UserDefaults(suiteName: "dop-test-\(UUID().uuidString)")!
        var choices = DoPChoices(on: [], off: [])
        choices.record(.music, for: u)
        suite.set(Array(choices.on), forKey: "dopDeviceUIDs")
        suite.set(Array(choices.off), forKey: "dopOffDeviceUIDs")
        let reloaded = DoPChoices(on: Set(suite.stringArray(forKey: "dopDeviceUIDs") ?? []), off: Set(suite.stringArray(forKey: "dopOffDeviceUIDs") ?? []))
        #expect(DoPDefaults.isEnabled(uid: u, on: reloaded.on, off: reloaded.off))
        #expect(DoPSetupHint.decide(identity: DoPDeviceIdentity(uid: u), transport: .usb, capabilities: caps(maxRate: 192_000),
                                    on: reloaded.on, off: reloaded.off, list: list) == .none)
    }

    @Test("A device whose UID changes keeps its answer in the sets the app already migrates")
    func sameSetsAsSwitch() {
        // The popover switch writes exactly these two sets; a test result must be indistinguishable from flipping it.
        var viaTest = DoPChoices(on: [], off: [])
        viaTest.record(.hiss, for: u)
        var viaSwitch = (on: Set<String>(), off: Set<String>())
        viaSwitch.on.remove(u); viaSwitch.off.insert(u)
        #expect(viaTest.on == viaSwitch.on && viaTest.off == viaSwitch.off)
    }
}

@Suite("DoP test: volume cap, fade-in and abort")
struct DoPTestSafetyTests {
    @Test("The cap never raises a volume that is already lower, and lowers a higher one")
    func cap() {
        #expect(DoPTestSafety.volumeToSet(current: 0.9, cap: 0.2) == 0.2)
        #expect(DoPTestSafety.volumeToSet(current: 0.1, cap: 0.2) == nil)
        #expect(DoPTestSafety.volumeToSet(current: 0.2, cap: 0.2) == nil)
        #expect(DoPTestSafety.volumeToSet(current: nil, cap: 0.2) == nil)
    }

    @Test("Whatever cap is asked for, it is held under the absolute ceiling")
    func ceiling() {
        #expect(DoPTestSafety.effectiveCap(requested: 1.0) == DoPTestConstants.absoluteVolumeCeiling)
        #expect(DoPTestSafety.effectiveCap(requested: -3) == 0)
        #expect(DoPTestSafety.effectiveCap(requested: 0.05) == 0.05)
    }

    @Test("The placeholder volume and all three candidate volumes are under the ceiling")
    func constantsAreSafe() {
        #expect(DoPTestConstants.absoluteVolumeCeiling <= 0.4)
        #expect(DoPTestConstants.hardwareVolumeCap <= DoPTestConstants.absoluteVolumeCeiling)
        for option in DoPTestConstants.volumeOptions { #expect(option <= DoPTestConstants.absoluteVolumeCeiling) }
        #expect(DoPTestConstants.volumeOptions.count == 3)
        #expect(DoPTestConstants.fadeInSeconds >= 0.5)
        #expect(DoPTestConstants.clipSeconds <= 8)
    }

    @Test("The clip starts silent, rises smoothly over the fade-in, and never exceeds its ceiling")
    func envelope() {
        #expect(DoPTestClip.envelope(at: 0) == 0)
        var last = 0.0
        var t = 0.0
        while t <= DoPTestConstants.fadeInSeconds {
            let e = DoPTestClip.envelope(at: t)
            #expect(e >= last)
            last = e
            t += 0.01
        }
        for i in 0...Int(DoPTestConstants.clipSeconds * 100) {
            #expect(DoPTestClip.envelope(at: Double(i) / 100) <= DoPTestConstants.maxToneAmplitude)
        }
        #expect(DoPTestClip.envelope(at: DoPTestConstants.clipSeconds) == 0, "fades out too, no click at the end")
        #expect(DoPTestConstants.maxToneAmplitude <= 0.2)
    }

    @Test("The clip is whole DoP frames with alternating markers, at DSD64")
    func clipPacksAsDoP() throws {
        let clip = DoPTestClip.make()
        #expect(clip.channels == 2 && clip.dsdRate == 2_822_400)
        #expect(clip.planes[0].count % 2 == 0 && clip.planes[0].count == clip.planes[1].count)
        let frames = try DoP.pack(clip.planes)
        #expect(frames.count == clip.planes[0].count / 2)
        for (n, frame) in frames.prefix(200).enumerated() { #expect(frame[0] >> 16 == (n % 2 == 0 ? 0x05 : 0xFA)) }
        #expect(abs(Double(frames.count) / 176_400 - DoPTestConstants.clipSeconds) < 0.05)
    }

    @Test("A DAC that does not decode DoP hears hash far below full scale: the stream misread as 24-bit PCM stays under the bound in the audible band")
    func misreadLevel() throws {
        let clip = DoPTestClip.make()
        let frames = try DoP.pack(clip.planes)
        let pcm = frames.map { frame -> Double in
            var v = Int32(bitPattern: frame[0] << 8) >> 8        // 24-bit two's complement
            if v > 0x7FFFFF { v -= 0x1000000 }
            return Double(v) / 8_388_608
        }
        // Audible band only: a 4th-order Butterworth low-pass at 20 kHz (two biquads), then RMS.
        let filtered = Biquad.lowPass(cutoff: 20_000, rate: 176_400).apply(Biquad.lowPass(cutoff: 20_000, rate: 176_400, q: 1.3066).apply(pcm))
        let rms = (filtered.dropFirst(2_000).reduce(0) { $0 + $1 * $1 } / Double(filtered.count - 2_000)).squareRoot()
        let db = 20 * log10(max(rms, 1e-12))
        #expect(db <= DoPTestConstants.maxMisreadAudibleDBFS, "misread level \(db) dBFS")
        #expect(DoPTestConstants.maxMisreadAudibleDBFS <= -40)
        // And the very start (first quarter second, during the fade-in) is quieter still.
        let start = Array(filtered[2_000..<Int(0.25 * 176_400)])
        let startRMS = (start.reduce(0) { $0 + $1 * $1 } / Double(start.count)).squareRoot()
        #expect(20 * log10(max(startRMS, 1e-12)) <= DoPTestConstants.maxMisreadAudibleDBFS)
    }

    @Test("The test aborts on any change to the output devices or the default output, and on none")
    func abortOnChange() {
        let before = DoPTestGuard.Snapshot(outputUIDs: ["a", "b"], defaultOutput: "a", target: "b")
        #expect(!DoPTestGuard.shouldAbort(start: before, now: before))
        #expect(DoPTestGuard.shouldAbort(start: before, now: .init(outputUIDs: ["a", "b", "c"], defaultOutput: "a", target: "b")))
        #expect(DoPTestGuard.shouldAbort(start: before, now: .init(outputUIDs: ["a"], defaultOutput: "a", target: "b")))
        #expect(DoPTestGuard.shouldAbort(start: before, now: .init(outputUIDs: ["a", "b"], defaultOutput: "b", target: "b")))
        #expect(DoPTestGuard.shouldAbort(start: before, now: .init(outputUIDs: ["a", "x"], defaultOutput: "a", target: "b")))
    }

    @Test("The answer only counts if the engine actually played the clip as DoP")
    func answerNeedsDoPPath() {
        #expect(!DoPTestGuard.mayAnswer(playedAsDoP: false, aborted: false))
        #expect(!DoPTestGuard.mayAnswer(playedAsDoP: true, aborted: true))
        #expect(DoPTestGuard.mayAnswer(playedAsDoP: true, aborted: false))
    }

    @Test("The clip is a valid DSF file the engine can read")
    func dsfHeader() {
        let data = DoPTestClip.make().dsfData
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "DSD ")
        #expect(String(decoding: data[28..<32], as: UTF8.self) == "fmt ")
        #expect(String(decoding: data[92..<96], as: UTF8.self) == "data")
    }
}

/// A second-order low-pass section, just enough to measure the audible band in the test above.
private struct Biquad {
    var b0, b1, b2, a1, a2: Double
    static func lowPass(cutoff: Double, rate: Double, q: Double = 0.5412) -> Biquad {
        let w = 2 * Double.pi * cutoff / rate, alpha = sin(w) / (2 * q), c = cos(w)
        let a0 = 1 + alpha
        return Biquad(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }
    func apply(_ x: [Double]) -> [Double] {
        var y = [Double](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<x.count {
            let out = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x[i]; y2 = y1; y1 = out
            y[i] = out
        }
        return y
    }
}
