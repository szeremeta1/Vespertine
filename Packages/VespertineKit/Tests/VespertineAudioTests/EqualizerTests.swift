//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CVespertineRT
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Parametric equalizer")
struct EqualizerTests {
    private func response(_ preset: EQPreset, _ f: Double, rate: Double = 48_000) -> Double {
        preset.responseDB(at: [f], sampleRate: rate)[0]
    }

    @Test("Peak and shelf filters have the gain they're set to, where they're set")
    func filterShapes() {
        let peak = EQPreset(name: "Peak", bands: [EQBand(kind: .peak, frequency: 1000, gainDB: 6, q: 1)])
        #expect(abs(response(peak, 1000) - 6) < 0.01)
        #expect(abs(response(peak, 50)) < 0.1 && abs(response(peak, 15_000)) < 0.1)

        let low = EQPreset(name: "Low", bands: [EQBand(kind: .lowShelf, frequency: 100, gainDB: 6, q: 0.707)])
        #expect(abs(response(low, 15) - 6) < 0.2 && abs(response(low, 100) - 3) < 0.1 && abs(response(low, 5000)) < 0.1)

        let high = EQPreset(name: "High", bands: [EQBand(kind: .highShelf, frequency: 8000, gainDB: -4, q: 0.707)])
        #expect(abs(response(high, 20_000) + 4) < 0.3 && abs(response(high, 100)) < 0.05)

        let hp = EQPreset(name: "HP", bands: [EQBand(kind: .highPass, frequency: 30, q: 0.707)])
        #expect(abs(response(hp, 30) + 3.01) < 0.05 && response(hp, 5) < -30)
    }

    @Test("Preamp shifts the whole curve, and the no-clipping preamp cancels the peak")
    func preamp() {
        let preset = EQPreset(name: "Boost", preampDB: -2, bands: [EQBand(kind: .peak, frequency: 3000, gainDB: 6, q: 2)])
        #expect(abs(response(preset, 3000) - 4) < 0.01)
        #expect(abs(preset.peakDB() - 4) < 0.05)
        #expect(abs(preset.preampForNoClipping() + 6) < 0.11)
        #expect(EQPreset(name: "Cut", bands: [EQBand(gainDB: -6)]).preampForNoClipping() == 0)
    }

    @Test("A preset that changes nothing is flat, so playback can stay bit-perfect")
    func flat() {
        #expect(EQPreset(name: "Empty").isFlat)
        #expect(EQPreset(name: "Zero", bands: [EQBand(gainDB: 0)]).isFlat)
        #expect(EQPreset(name: "Off", bands: [EQBand(gainDB: 5, enabled: false)]).isFlat)
        #expect(!EQPreset(name: "Preamp", preampDB: -1).isFlat)
        #expect(!EQPreset(name: "Pass", bands: [EQBand(kind: .highPass, frequency: 20)]).isFlat)
    }

    @Test("Bands above what the sample rate carries are left out, except a low shelf, which becomes a gain")
    func aboveNyquist() {
        let bands = [EQBand(kind: .peak, frequency: 30_000, gainDB: 6), EQBand(kind: .lowShelf, frequency: 30_000, gainDB: -6)]
        let sections = EQPreset(name: "High", bands: bands).sections(sampleRate: 44_100)
        #expect(sections.count == 1 && abs(sections[0].b0 - pow(10, -6.0 / 20)) < 1e-12 && sections[0].a1 == 0)
        #expect(EQPreset(name: "High", bands: bands).sections(sampleRate: 96_000).count == 2)
    }

    @Test("Reads AutoEQ's ParametricEQ.txt")
    func autoEQ() throws {
        let text = """
        Preamp: -6.4 dB
        Filter 1: ON LSC Fc 105 Hz Gain 6.0 dB Q 0.70
        Filter 2: ON PK Fc 2400 Hz Gain -3.1 dB Q 1.41
        Filter 3: OFF PK Fc 5000 Hz Gain 2 dB Q 4
        Filter 4: ON HSC Fc 10000 Hz Gain -2.5 dB Q 0.70
        """
        let preset = try EQPreset.parse(text, name: "HD 650")
        #expect(preset.name == "HD 650" && preset.preampDB == -6.4)
        #expect(preset.bands.map(\.kind) == [.lowShelf, .peak, .peak, .highShelf])
        #expect(preset.bands[1].frequency == 2400 && preset.bands[1].gainDB == -3.1 && preset.bands[1].q == 1.41)
        #expect(!preset.bands[2].enabled && preset.bands[0].enabled)
    }

    @Test("Reads Equalizer APO's own forms: bandwidth in octaves, decimal commas, other commands ignored")
    func equalizerAPO() throws {
        let text = """
        # My settings
        Device: Speakers
        Preamp: -3,5 dB
        Filter: ON PK Fc 1000 Hz Gain 4 dB BW Oct 1
        Filter: ON HP Fc 20 Hz
        Include: other.txt
        """
        let preset = try EQPreset.parse(text, name: "APO")
        #expect(preset.preampDB == -3.5 && preset.bands.count == 2)
        #expect(abs(preset.bands[0].q - 1.4142) < 0.001)   // one octave
        #expect(preset.bands[1].kind == .highPass && preset.bands[1].q == 0.707)
    }

    @Test("Files Vespertine can't use say why")
    func importErrors() {
        #expect(throws: EQImportError.graphicEQ) { try EQPreset.parse("GraphicEQ: 20 -1; 30 -2", name: "x") }
        #expect(throws: EQImportError.noFilters) { try EQPreset.parse("Preamp: -2 dB", name: "x") }
        #expect(throws: EQImportError.unsupportedFilter(line: 1, type: "BP")) { try EQPreset.parse("Filter 1: ON BP Fc 100 Hz", name: "x") }
        #expect(throws: EQImportError.unreadable(line: 2)) { try EQPreset.parse("Preamp: 0 dB\nFilter 1: ON PK Gain 3 dB", name: "x") }
        let many = (1...(EQPreset.maxBands + 1)).map { "Filter \($0): ON PK Fc \(100 * $0) Hz Gain 1 dB Q 1" }.joined(separator: "\n")
        #expect(throws: EQImportError.tooManyFilters(EQPreset.maxBands + 1)) { try EQPreset.parse(many, name: "x") }
    }

    @Test("Export reads back as the same preset")
    func roundTrip() throws {
        let preset = EQPreset(name: "Mine", preampDB: -4.5, bands: [
            EQBand(kind: .lowShelf, frequency: 90, gainDB: 4.5, q: 0.71),
            EQBand(kind: .peak, frequency: 3150, gainDB: -2.5, q: 2.5, enabled: false),
            EQBand(kind: .lowPass, frequency: 18000, q: 0.71),
        ])
        let back = try EQPreset.parse(preset.apoText, name: "Mine")
        #expect(back.preampDB == preset.preampDB)
        #expect(back.bands.map(\.kind) == preset.bands.map(\.kind))
        #expect(back.bands.map(\.frequency) == preset.bands.map(\.frequency))
        #expect(back.bands.map(\.gainDB) == preset.bands.map(\.gainDB))
        #expect(back.bands.map(\.q) == preset.bands.map(\.q))
        #expect(back.bands.map(\.enabled) == preset.bands.map(\.enabled))
    }

    @Test("The render path applies the sections: a 1 kHz tone through a +6 dB peak comes out twice as loud")
    func render() {
        let preset = EQPreset(name: "Peak", bands: [EQBand(kind: .peak, frequency: 1000, gainDB: 20 * log10(2), q: 1)])
        let ring = nrt_ring_create(8192, 1)!
        let context = nrt_context_create(ring, 512)!
        defer { nrt_context_destroy(context); nrt_ring_destroy(ring) }
        nrt_context_set_gain(context, 1, 32)
        let sections = preset.sections(sampleRate: 48_000)
        sections.withUnsafeBufferPointer { nrt_context_set_eq(context, $0.baseAddress, UInt32($0.count), preset.preampGain) }
        let input = (0..<4096).map { Float(0.25 * sin(2 * Double.pi * 1000 * Double($0) / 48_000)) }
        #expect(nrt_ring_write(ring, input, 4096) == 4096)
        var output = [Float](repeating: 0, count: 4096)
        nrt_context_render_interleaved(context, &output, 4096, 1)
        let settled = output[2048...].map(abs).max() ?? 0
        #expect(abs(settled - 0.5) < 0.002)

        // Turned off, the samples go through untouched again.
        nrt_context_set_eq(context, nil, 0, 1)
        #expect(nrt_ring_write(ring, input, 4096) == 4096)
        nrt_context_render_interleaved(context, &output, 4096, 1)
        #expect(output == input)
    }

    @Test("The signal path says the equalizer is on, and doesn't call it bit-perfect")
    func signalPath() {
        let source = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 48_000, bitDepth: 24, channels: 2)
        let plan = FormatPlanner.plan(source: source, device: DeviceCapabilities(sampleRates: [48_000], physicalFormats: [],
                                                                                 outputChannels: 2, supportsDoP: false))
        let applied = AppliedFormat(sampleRate: 48_000, physicalBitDepth: 32, physicalIsInteger: false, virtualChannels: 2,
                                    exclusive: true, bufferFrames: 512)
        var path = SignalPath(source: source, decoderName: "test", plan: plan, applied: applied, deviceName: "DAC", deviceUID: "DAC",
                              deviceProfile: DeviceProfile(kind: .usbDAC, tag: "USB", canBeBitPerfect: true, symbol: "x"), volume: .fixed)
        #expect(path.isBitPerfect)
        path.equalizer = "HD 650"
        #expect(!path.isBitPerfect && path.statusLine == "EQUALIZER")
    }
}
