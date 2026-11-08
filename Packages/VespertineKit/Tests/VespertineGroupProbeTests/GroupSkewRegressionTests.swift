//
// Vespertine — group-skew against real captures. The recordings are from the hardware session of 2026-11-07 (Fosi ZD3 leader, FiiO K11
// follower with drift correction, UMIK-1): the follower's chirp reaches the microphone 16 dB under the leader's and its first arrival
// can fade below a later copy 162 frames on, which lost four runs of twenty and made two others lock onto the copy.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio
@testable import VespertineGroupProbe

@Suite("Group skew on real captures")
struct GroupSkewRegressionTests {
    /// A fixture capture: see Fixtures/README.md for the format.
    static func recording(_ name: String) throws -> [Float] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "s16z", subdirectory: "Fixtures/run1927"))
        let file = try Data(contentsOf: url)
        let scale = file.prefix(4).withUnsafeBytes { Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        let raw = try (file.dropFirst(4) as NSData).decompressed(using: .zlib) as Data
        return raw.withUnsafeBytes { buffer in
            (0..<(raw.count / 2)).map { Float(Int16(littleEndian: buffer.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) * scale }
        }
    }

    static func measure(_ name: String, leadIn: Double) throws -> GroupSkew.Measurement {
        let layout = try GroupSkew.layout(rate: 48_000, leadIn: leadIn, level: 0.1)
        return try GroupSkew.measure(samples: recording(name), layout: layout)
    }

    @Test func aGoodCaptureKeepsItsLoggedSkew() throws {
        let m = try Self.measure("h3-run-1", leadIn: 1.5)
        #expect(abs(m.skewFrames - 630.684) < 0.05)
    }

    @Test("The four H3 runs that lost the timing reference now locate the follower where the others do", arguments: [2, 6, 13, 16])
    func lostRunsLocate(run: Int) throws {
        let m = try Self.measure("h3-run-\(run)", leadIn: 1.5)
        #expect((627...634).contains(m.skewFrames), "run \(run): \(m.skewFrames)")
    }

    @Test func theFollowerCopy186FramesLateIsNoLongerPicked() throws {
        let m = try Self.measure("h3-run-18", leadIn: 1.5)
        #expect((627...634).contains(m.skewFrames), "\(m.skewFrames) (was +816)")
    }

    @Test func aFadedFirstArrivalInTheLeadInSeriesIsNotSkippedEither() throws {
        // H4 run 20: the follower chirp 15.6 s after the start; the line through the series puts it near 639 frames.
        let m = try Self.measure("h4-run-20", leadIn: 15)
        #expect((635...644).contains(m.skewFrames), "\(m.skewFrames) (was +801)")
    }
}
