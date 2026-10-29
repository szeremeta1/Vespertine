//
// Vespertine — measurement microphone calibration files (miniDSP UMIK-1 style): reading them, rejecting damaged ones,
// and turning the microphone's response into the correction a measurement needs.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Microphone calibration")
struct MicCalibrationTests {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures")!)
    }

    private func parse(_ text: String) throws -> MicCalibration { try MicCalibration.parse(Data(text.utf8)) }

    @Test("The 0° file (synthetic, UMIK-1 layout) reads its header, sensitivity and every row")
    func zeroDegreeFile() throws {
        let cal = try MicCalibration.parse(try fixture("umik-synthetic"))
        #expect(cal.serial == "0000001")
        #expect(cal.sensitivityDB == -1.5)
        #expect(cal.points.count == 615)
        #expect(cal.points.first == MicCalibration.Point(hz: 10.054, db: -3.5625))
        #expect(cal.points.last == MicCalibration.Point(hz: 20016.816, db: 0.0395))
        #expect(zip(cal.points, cal.points.dropFirst()).allSatisfy { $0.hz < $1.hz })
    }

    @Test("The 90° file has an extra comment line and the same grid, and its levels differ from the 0° file")
    func ninetyDegreeFile() throws {
        let zero = try MicCalibration.parse(try fixture("umik-synthetic"))
        let ninety = try MicCalibration.parse(try fixture("umik-synthetic_90deg"))
        #expect(ninety.serial == "0000001" && ninety.sensitivityDB == -1.5)
        #expect(ninety.points.map(\.hz) == zero.points.map(\.hz))
        #expect(ninety.points.map(\.db) != zero.points.map(\.db))
        // The two files differ most at high frequencies, where the capsule's directivity shows.
        #expect(abs(ninety.gainDB(at: 15_000) - zero.gainDB(at: 15_000)) > 1)
    }

    @Test("The hash is of the file's original bytes, so a re-saved file is a different calibration")
    func hashOfBytes() throws {
        let data = try fixture("umik-synthetic")
        let cal = try MicCalibration.parse(data)
        #expect(cal.sha256 == "6a2fcb3254461a5daa3889fbc6038389796bd3db64186e7165a41b857810b144")
        #expect(try MicCalibration.parse(Data((String(decoding: data, as: UTF8.self) + "\n").utf8)).sha256 != cal.sha256)
    }

    @Test("Interpolation is linear in dB against log frequency, and holds the end values outside the file")
    func interpolation() throws {
        let cal = try parse("\"Sens Factor =0dB, SERNO: 1\"\n100\t0\n1000\t4\n10000\t-2\n")
        #expect(abs(cal.gainDB(at: 100)) < 1e-12 && abs(cal.gainDB(at: 1000) - 4) < 1e-12)
        #expect(abs(cal.gainDB(at: sqrt(100.0 * 1000.0)) - 2) < 1e-9)
        #expect(abs(cal.gainDB(at: sqrt(1000.0 * 10_000.0)) - 1) < 1e-9)
        #expect(cal.gainDB(at: 20) == 0 && cal.gainDB(at: 20_000) == -2)
    }

    @Test("Compensation is the opposite of the microphone's response: a microphone reading 3 dB high is turned down 3 dB")
    func compensationSign() throws {
        let cal = try parse("100\t3\n1000\t-6\n")
        #expect(cal.compensationDB(at: 100) == -3)
        #expect(cal.compensationDB(at: 1000) == 6)
        let comp = cal.compensationDB(at: [100, 1000])
        #expect(comp == [-3, 6])
        // Applying it to what the microphone reported (true level 0 dB plus its own response) gives back the true level.
        for f in [100.0, 316.0, 1000.0] { #expect(abs(cal.gainDB(at: f) + cal.compensationDB(at: f)) < 1e-12) }
    }

    @Test("The sensitivity factor is optional, and a header without a serial is fine")
    func optionalHeader() throws {
        let none = try parse("100\t0\n200\t1\n")
        #expect(none.serial == nil && none.sensitivityDB == nil && none.points.count == 2)
        let sensOnly = try parse("\"Sens Factor =+2.5dB\"\n100\t0\n200\t1\n")
        #expect(sensOnly.sensitivityDB == 2.5 && sensOnly.serial == nil)
    }

    @Test("Windows line endings, blank lines, comment lines and spaces between columns are read")
    func looseFormatting() throws {
        let cal = try parse("\"Sens Factor =-1.2dB, SERNO: 9\"\r\n\"a comment\"\r\n* another\r\n\r\n100 0.5\r\n200\t1.5\r\n\r\n")
        #expect(cal.points == [.init(hz: 100, db: 0.5), .init(hz: 200, db: 1.5)])
    }

    @Test("Rows given out of order are sorted")
    func unsorted() throws {
        #expect(try parse("200\t1\n100\t0\n").points.map(\.hz) == [100, 200])
    }

    @Test("A repeated frequency with the same level counts once; with a different level the file is refused")
    func duplicates() throws {
        #expect(try parse("100\t0\n100\t0\n200\t1\n").points.count == 2)
        #expect(try parse("100\t0\n100.000\t0.0\n200\t1\n").points.count == 2)
        #expect(throws: MicCalibrationError.conflictingDuplicate(line: 2, hz: 100)) { try parse("100\t0\n100\t1\n200\t1\n") }
    }

    @Test("Damaged files are refused with the line that is wrong, and nothing is guessed")
    func malformed() {
        #expect(throws: MicCalibrationError.malformedRow(line: 2)) { try parse("100\t0\nabc\t1\n") }
        #expect(throws: MicCalibrationError.malformedRow(line: 2)) { try parse("100\t0\n200\n") }
        #expect(throws: MicCalibrationError.malformedRow(line: 2)) { try parse("100\t0\n200\t1\t7\n") }
        #expect(throws: MicCalibrationError.malformedRow(line: 2)) { try parse("100\t0\n200,5\t1\n") }
        #expect(throws: MicCalibrationError.notFinite(line: 2)) { try parse("100\t0\n200\tnan\n") }
        #expect(throws: MicCalibrationError.notFinite(line: 2)) { try parse("100\t0\n200\tinf\n") }
        #expect(throws: MicCalibrationError.invalidFrequency(line: 1)) { try parse("0\t0\n200\t1\n") }
        #expect(throws: MicCalibrationError.invalidFrequency(line: 1)) { try parse("-5\t0\n200\t1\n") }
        #expect(throws: MicCalibrationError.malformedHeader) { try parse("\"Sens Factor =loud, SERNO: 1\"\n100\t0\n200\t1\n") }
        #expect(throws: MicCalibrationError.outOfRange(line: 2)) { try parse("100\t0\n200\t90\n") }
    }

    @Test("A file with no data, or one point, can't be a calibration; invalid UTF-8 is refused")
    func tooShort() {
        #expect(throws: MicCalibrationError.tooFewPoints) { try parse("") }
        #expect(throws: MicCalibrationError.tooFewPoints) { try parse("\"Sens Factor =0dB, SERNO: 1\"\n") }
        #expect(throws: MicCalibrationError.tooFewPoints) { try parse("100\t0\n") }
        #expect(throws: MicCalibrationError.notText) { try MicCalibration.parse(Data([0xFF, 0xFE, 0x00, 0x31])) }
    }

    @Test("The calibration's identity can be recorded on a session's microphone")
    func recordsOnSession() throws {
        let cal = try MicCalibration.parse(try fixture("umik-synthetic"))
        let mic = cal.mic(orientation: .towardSpeaker)
        #expect(mic == RoomMic(serial: "0000001", orientation: .towardSpeaker, calibrationSHA256: cal.sha256, sensitivityDB: -1.5))
    }
}
