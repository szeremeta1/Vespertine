//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Equalizer import of imperfect files")
struct EqualizerImportTests {
    @Test("A Windows file (CRLF line ends) reports the line a problem is on, not twice that")
    func crlfLineNumbers() {
        let text = "Preamp: -3 dB\r\nFilter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1\r\nFilter 2: ON PK Gain 3 dB\r\n"
        #expect(throws: EQImportError.unreadable(line: 3)) { try EQPreset.parse(text, name: "x") }
        // Old Mac line ends (a lone CR) too.
        #expect(throws: EQImportError.unreadable(line: 3)) { try EQPreset.parse(text.replacingOccurrences(of: "\r\n", with: "\r"), name: "x") }
    }

    @Test("A byte order mark at the start of the file doesn't hide the first line (the preamp)")
    func byteOrderMark() throws {
        let preset = try EQPreset.parse("\u{FEFF}Preamp: -6.5 dB\nFilter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1\n", name: "x")
        #expect(preset.preampDB == -6.5)
        #expect(preset.bands.count == 1)
    }

    @Test("A frequency outside what the editor allows is brought into range, as gain and Q are")
    func frequencyIsClamped() throws {
        let preset = try EQPreset.parse("Filter 1: ON PK Fc 1e300 Hz Gain 3 dB Q 1\nFilter 2: ON PK Fc 0.001 Hz Gain 3 dB Q 1", name: "x")
        #expect(preset.bands.map(\.frequency) == [EQBand.frequencyRange.upperBound, EQBand.frequencyRange.lowerBound])
        // What it exports reads back.
        let back = try EQPreset.parse(preset.apoText, name: "x")
        #expect(back.bands.map(\.frequency) == preset.bands.map(\.frequency))
    }

    @Test("A gain or Q that is there but isn't a number is a problem with the line, not a band that does nothing")
    func unreadableValues() {
        for bad in ["Gain dB", "Gain nan dB", "Gain abc dB", "Q", "Q nan", "Q x"] {
            let line = "Filter 1: ON PK Fc 1000 Hz \(bad)"
            #expect(throws: EQImportError.unreadable(line: 1), "\(bad)") { try EQPreset.parse(line, name: "x") }
        }
        // Left out is fine: no gain is 0 dB, no Q is 0.707 (shelves and passes in AutoEQ files give one, peaks always).
        #expect(throws: Never.self) { try EQPreset.parse("Filter 1: ON HP Fc 80 Hz", name: "x") }
    }

    @Test("Infinite, absurd and out-of-range numbers never reach the filters")
    func absurdNumbers() throws {
        let preset = try EQPreset.parse("Preamp: -1e9 dB\nFilter 1: ON PK Fc 1000 Hz Gain 1e30 dB Q 1e30\nFilter 2: ON LSC Fc 100 Hz Gain -1e30 dB Q -5", name: "x")
        #expect(preset.preampDB == EQPreset.preampRange.lowerBound)
        #expect(preset.bands.allSatisfy { EQBand.gainRange.contains($0.gainDB) && EQBand.qRange.contains($0.q) })
        #expect(preset.peakDB(sampleRate: 48_000).isFinite)
        #expect(throws: EQImportError.unreadable(line: 1)) { try EQPreset.parse("Preamp: 1e999 dB\nFilter 1: ON PK Fc 1000 Hz", name: "x") }
    }

    @Test("A file with very many filters is turned away at once, with the count")
    func hugeBandCount() {
        let text = (1...20_000).map { "Filter \($0): ON PK Fc 1000 Hz Gain 1 dB Q 1" }.joined(separator: "\n")
        #expect(throws: EQImportError.tooManyFilters(20_000)) { try EQPreset.parse(text, name: "x") }
    }

    @Test("Files saved as UTF-16 (a Windows editor's \"Unicode\") or in an old code page are read")
    func encodings() throws {
        let text = "# Kopfh\u{00F6}rer\nPreamp: -4 dB\r\nFilter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1\r\n"
        let utf8 = Data(text.utf8)
        let le = Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
        let be = Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!
        let latin1 = text.data(using: .isoLatin1)!
        #expect(utf8 != latin1)
        for (label, data) in [("UTF-8", utf8), ("UTF-16 LE", le), ("UTF-16 BE", be), ("Latin-1", latin1)] {
            let preset = try EQPreset.parse(data, name: "x")
            #expect(preset.preampDB == -4 && preset.bands.count == 1, "\(label)")
        }
        // Something that isn't text says so the same way any file without filters does.
        #expect(throws: EQImportError.self) { try EQPreset.parse(Data([0x00, 0xFF, 0x13, 0x80, 0x0A, 0x7F]), name: "x") }
    }
}
