//
// Vespertine verification: writes the IEC 61937 carriers Vespertine sends for the Dolby test files, for the
// oracle job in CI (oracles/iec61937/check_carriers.py: FFmpeg's S/PDIF demuxer and the blind carrier scanner),
// and records that a DTS file has none (FINDINGS.md F-02).
// SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import Foundation
import Testing
import VespertineAdapters

/// The Dolby fixtures of Vespertine's own tests (1.5 s of 5.1 tones; see their README).
let carrierSources = ["dolby-digital-tones.ac3", "dolby-digital-plus-tones.ec3", "dolby-digital-plus-tones.m4a"]

let vespertineFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()          // AcceptanceTests
    .deletingLastPathComponent().deletingLastPathComponent()                        // harness
    .deletingLastPathComponent().deletingLastPathComponent()                        // repository
    .appendingPathComponent("Packages/VespertineKit/Tests/VespertineAudioTests/Fixtures")

@Test("IEC 61937 carriers for the oracle job", .enabled(if: ProcessInfo.processInfo.environment["VERIFICATION_IEC_OUT"] != nil))
func writeIECCarriers() throws {
    let out = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VERIFICATION_IEC_OUT"]))
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for name in carrierSources {
        try Vespertine.writeCarrier(from: vespertineFixtures.appendingPathComponent(name), to: out.appendingPathComponent(name + ".iec.wav"))
    }
}

/// FINDINGS.md F-02: docs/VERIFICATION.md line 61 says DTS frames go out byte for byte inside the IEC 61937 carrier.
/// Vespertine makes no IEC 61937 carrier for a DTS file (DTS CDs go out as stored, other DTS is decoded), so this
/// fails, as a known issue, until a DTS carrier exists or the line is corrected.
@Test("F-02: a DTS file has an IEC 61937 carrier")
func dtsCarrier() {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-dts-carrier-\(getpid()).wav")
    defer { try? FileManager.default.removeItem(at: out) }
    withKnownIssue("F-02 (FINDINGS.md)") {
        try Vespertine.writeCarrier(from: vespertineFixtures.appendingPathComponent("dts-tones.dts"), to: out)
    }
}
#endif
