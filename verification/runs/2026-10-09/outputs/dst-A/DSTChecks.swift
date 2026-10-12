//
// Spec-traced checks for contracts/dst-decode.md: requirement records DST-001 … DST-004.
// DST-005 and DST-006 are `testable: false` and are not checked.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The fixtures (DSTFixtures.all) are the only DST frames there are; nothing else is assumed about the frame format.
// Other byte sequences (a fixture cut short or extended, the empty frame, another channel count's stored frame) are
// only used to check what holds for every frame (DST-001: a decoded frame is 4 704 bytes per channel, so the result
// is nil or exactly that long) and, in sequences, that a fixture still decodes to its DSD afterwards (frames are
// independent). What such bytes decode to, and whether they decode at all, is left open (DST-005 is not available).
//
// Every check makes its own decoders; none is shared between checks or scenarios. Each check decodes at most a
// handful of frames so it stays within a few seconds in a debug build.
//

import Contracts
import SpecKit

public enum DSTChecks {
    public static let all: [SpecCheck<any DSTDecoderMaker>] = [

        // MARK: Every fixture frame, each with a fresh decoder

        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("2ch-v0 (DST-coded) decodes to the DSD it encodes",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            try DSTSpecSupport.checkFixture("2ch-v0", maker, checker)
        },
        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("2ch-v1 (DST-coded) decodes to the DSD it encodes",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            try DSTSpecSupport.checkFixture("2ch-v1", maker, checker)
        },
        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("2ch-v2 (DST-coded) decodes to the DSD it encodes",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            try DSTSpecSupport.checkFixture("2ch-v2", maker, checker)
        },
        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("2ch-v3 (DST-coded) decodes to the DSD it encodes",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            try DSTSpecSupport.checkFixture("2ch-v3", maker, checker)
        },
        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("2ch-v4 (DST-coded) decodes to the DSD it encodes",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            try DSTSpecSupport.checkFixture("2ch-v4", maker, checker)
        },
        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("2ch-v5 (DST-coded) decodes to the DSD it encodes",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            try DSTSpecSupport.checkFixture("2ch-v5", maker, checker)
        },
        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("2ch-stored (uncompressed) decodes to the DSD it holds",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            try DSTSpecSupport.checkFixture("2ch-stored", maker, checker)
        },
        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("5ch-v0 (DST-coded) decodes to the DSD it encodes",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            try DSTSpecSupport.checkFixture("5ch-v0", maker, checker)
        },
        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("5ch-v1 (DST-coded) decodes to the DSD it encodes",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            try DSTSpecSupport.checkFixture("5ch-v1", maker, checker)
        },
        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("5ch-v2 (DST-coded) decodes to the DSD it encodes",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            try DSTSpecSupport.checkFixture("5ch-v2", maker, checker)
        },
        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("5ch-stored (uncompressed) decodes to the DSD it holds",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            try DSTSpecSupport.checkFixture("5ch-stored", maker, checker)
        },
        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("6ch-v0 (DST-coded) decodes to the DSD it encodes",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            try DSTSpecSupport.checkFixture("6ch-v0", maker, checker)
        },
        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("6ch-v1 (DST-coded) decodes to the DSD it encodes",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            try DSTSpecSupport.checkFixture("6ch-v1", maker, checker)
        },
        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("6ch-v2 (DST-coded) decodes to the DSD it encodes",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            try DSTSpecSupport.checkFixture("6ch-v2", maker, checker)
        },
        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("6ch-stored (uncompressed) decodes to the DSD it holds",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            try DSTSpecSupport.checkFixture("6ch-stored", maker, checker)
        },

        // MARK: Sequences on one decoder: the result for a frame must not depend on earlier frames

        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("one 2ch decoder decodes every 2ch fixture in turn",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            let names = ["2ch-v0", "2ch-v1", "2ch-v2", "2ch-v3", "2ch-v4", "2ch-v5", "2ch-stored"]
            let steps = try names.map { DSTSpecSupport.Step.fixture(try DSTSpecSupport.fixture($0)) }
            DSTSpecSupport.run(steps, on: maker.makeDecoder(channels: 2), channels: 2, checker)
        },
        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("one 2ch decoder: a frame twice in a row, stored and DST-coded frames alternating",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            let names = ["2ch-v5", "2ch-v5", "2ch-stored", "2ch-v2", "2ch-stored", "2ch-stored", "2ch-v0", "2ch-v5"]
            let steps = try names.map { DSTSpecSupport.Step.fixture(try DSTSpecSupport.fixture($0)) }
            DSTSpecSupport.run(steps, on: maker.makeDecoder(channels: 2), channels: 2, checker)
        },
        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("one 5ch decoder: a frame twice in a row, then a stored frame",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            let names = ["5ch-v0", "5ch-v0", "5ch-stored"]
            let steps = try names.map { DSTSpecSupport.Step.fixture(try DSTSpecSupport.fixture($0)) }
            DSTSpecSupport.run(steps, on: maker.makeDecoder(channels: 5), channels: 5, checker)
        },
        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("one 5ch decoder: stored frame first, then two different DST-coded frames",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            let names = ["5ch-stored", "5ch-v1", "5ch-v2", "5ch-stored"]
            let steps = try names.map { DSTSpecSupport.Step.fixture(try DSTSpecSupport.fixture($0)) }
            DSTSpecSupport.run(steps, on: maker.makeDecoder(channels: 5), channels: 5, checker)
        },
        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("one 6ch decoder: two different DST-coded frames, then a stored frame",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            let names = ["6ch-v0", "6ch-v1", "6ch-stored"]
            let steps = try names.map { DSTSpecSupport.Step.fixture(try DSTSpecSupport.fixture($0)) }
            DSTSpecSupport.run(steps, on: maker.makeDecoder(channels: 6), channels: 6, checker)
        },
        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("one 6ch decoder: a frame twice in a row around a stored frame",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            let names = ["6ch-stored", "6ch-v2", "6ch-v2", "6ch-stored"]
            let steps = try names.map { DSTSpecSupport.Step.fixture(try DSTSpecSupport.fixture($0)) }
            DSTSpecSupport.run(steps, on: maker.makeDecoder(channels: 6), channels: 6, checker)
        },

        // MARK: Sequences across decoders: no state shared between decoder objects

        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("two 2ch decoders used in alternation",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            let v0 = try DSTSpecSupport.fixture("2ch-v0"), v3 = try DSTSpecSupport.fixture("2ch-v3")
            let st = try DSTSpecSupport.fixture("2ch-stored")
            let a = maker.makeDecoder(channels: 2), b = maker.makeDecoder(channels: 2)
            let calls: [(any DSTFrameDecoder, String, DSTFixture)] = [
                (a, "decoder A", v0), (b, "decoder B", v3), (a, "decoder A", v3), (b, "decoder B", st),
                (a, "decoder A", st), (b, "decoder B", v0),
            ]
            for (i, call) in calls.enumerated() {
                DSTSpecSupport.verify(call.0.decode(frame: call.2.frame), call.2,
                                      "call \(i + 1), \(call.1), \(call.2.name)", checker)
            }
        },
        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("2ch, 5ch and 6ch decoders used in alternation",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            let d2 = maker.makeDecoder(channels: 2), d5 = maker.makeDecoder(channels: 5)
            let d6 = maker.makeDecoder(channels: 6)
            let calls: [(any DSTFrameDecoder, String)] = [
                (d2, "2ch-v4"), (d6, "6ch-v0"), (d5, "5ch-v0"), (d2, "2ch-stored"), (d6, "6ch-stored"),
                (d5, "5ch-stored"), (d2, "2ch-v1"),
            ]
            for (i, call) in calls.enumerated() {
                let f = try DSTSpecSupport.fixture(call.1)
                DSTSpecSupport.verify(call.0.decode(frame: f.frame), f, "call \(i + 1), \(f.name)", checker)
            }
        },

        // MARK: Sequences with altered frames in between: fixtures still decode to their DSD afterwards

        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("one 2ch decoder: fixtures still decode after empty, cut, extended and foreign frames",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            typealias S = DSTSpecSupport
            let v3 = try S.fixture("2ch-v3"), v1 = try S.fixture("2ch-v1"), v0 = try S.fixture("2ch-v0")
            let st = try S.fixture("2ch-stored"), st6 = try S.fixture("6ch-stored")
            let steps: [S.Step] = [
                .altered("empty frame", []),
                .altered("2ch-v3 cut to half its length", S.prefix(v3.frame, v3.frame.count / 2)),
                .fixture(v3),
                .altered("2ch-stored without its last byte", S.droppingLast(st.frame, 1)),
                .fixture(st),
                .altered("2ch-v1 with two bytes appended", v1.frame + [0x00, 0xFF]),
                .fixture(v1),
                .altered("the 6ch-stored frame", st6.frame),
                .fixture(v0),
            ]
            S.run(steps, on: maker.makeDecoder(channels: 2), channels: 2, checker)
        },
        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("one 5ch decoder: fixtures still decode after cut frames",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            typealias S = DSTSpecSupport
            let v2 = try S.fixture("5ch-v2"), st = try S.fixture("5ch-stored")
            let steps: [S.Step] = [
                .altered("5ch-v2 without its last byte", S.droppingLast(v2.frame, 1)),
                .fixture(v2),
                .altered("5ch-stored cut to 100 bytes", S.prefix(st.frame, 100)),
                .fixture(st),
            ]
            S.run(steps, on: maker.makeDecoder(channels: 5), channels: 5, checker)
        },
        // REQ: DST-001, DST-002, DST-003, DST-004
        SpecCheck("one 6ch decoder: fixtures still decode after cut and foreign frames",
                  requirements: ["DST-001", "DST-002", "DST-003", "DST-004"]) { maker, checker in
            typealias S = DSTSpecSupport
            let v1 = try S.fixture("6ch-v1"), v0 = try S.fixture("6ch-v0"), st = try S.fixture("6ch-stored")
            let other = try S.fixture("2ch-stored")
            let steps: [S.Step] = [
                .altered("6ch-stored without its last byte", S.droppingLast(st.frame, 1)),
                .fixture(v0),
                .altered("the 2ch-stored frame", other.frame),
                .fixture(st),
                .altered("6ch-v1 cut to half its length", S.prefix(v1.frame, v1.frame.count / 2)),
                .fixture(st),
            ]
            S.run(steps, on: maker.makeDecoder(channels: 6), channels: 6, checker)
        },

        // MARK: DST-001 for any frame: the result is nil or exactly 4 704 bytes per channel

        // REQ: DST-001
        SpecCheck("2ch decoder: altered stored frames give nil or 9 408 bytes", requirements: ["DST-001"]) { maker, checker in
            try DSTSpecSupport.checkAlteredStored("2ch-stored", others: ["5ch-stored", "6ch-stored"], maker, checker)
        },
        // REQ: DST-001
        SpecCheck("5ch decoder: altered stored frames give nil or 23 520 bytes", requirements: ["DST-001"]) { maker, checker in
            try DSTSpecSupport.checkAlteredStored("5ch-stored", others: ["2ch-stored", "6ch-stored"], maker, checker)
        },
        // REQ: DST-001
        SpecCheck("6ch decoder: altered stored frames give nil or 28 224 bytes", requirements: ["DST-001"]) { maker, checker in
            try DSTSpecSupport.checkAlteredStored("6ch-stored", others: ["2ch-stored", "5ch-stored"], maker, checker)
        },
        // REQ: DST-001
        SpecCheck("2ch decoder: altered DST-coded frames give nil or 9 408 bytes", requirements: ["DST-001"]) { maker, checker in
            typealias S = DSTSpecSupport
            let f = try S.fixture("2ch-v3")
            let frames: [(String, [UInt8])] = [
                ("2ch-v3 without its last byte", S.droppingLast(f.frame, 1)),
                ("2ch-v3 cut to three quarters", S.prefix(f.frame, f.frame.count * 3 / 4)),
                ("2ch-v3 cut to half", S.prefix(f.frame, f.frame.count / 2)),
                ("2ch-v3 with one byte appended", f.frame + [0x00]),
                ("2ch-v3 twice over", f.frame + f.frame),
            ]
            S.checkFrameSizes(frames, channels: 2, maker, checker)
        },
        // REQ: DST-001
        SpecCheck("5ch decoder: altered DST-coded frames give nil or 23 520 bytes", requirements: ["DST-001"]) { maker, checker in
            typealias S = DSTSpecSupport
            let f = try S.fixture("5ch-v1")
            let frames: [(String, [UInt8])] = [
                ("5ch-v1 cut to two thirds", S.prefix(f.frame, f.frame.count * 2 / 3)),
                ("5ch-v1 with 16 bytes appended", f.frame + [UInt8](repeating: 0xA5, count: 16)),
            ]
            S.checkFrameSizes(frames, channels: 5, maker, checker)
        },
        // REQ: DST-001
        SpecCheck("6ch decoder: altered DST-coded frames give nil or 28 224 bytes", requirements: ["DST-001"]) { maker, checker in
            typealias S = DSTSpecSupport
            let f = try S.fixture("6ch-v2")
            let frames: [(String, [UInt8])] = [
                ("6ch-v2 without its last byte", S.droppingLast(f.frame, 1)),
                ("6ch-v2 with 4 704 bytes appended", f.frame + [UInt8](repeating: 0x69, count: 4704)),
            ]
            S.checkFrameSizes(frames, channels: 6, maker, checker)
        },
    ]
}

// MARK: - Support

private enum DSTSpecSupport {
    /// DST-001: 37 632 DSD samples per channel per frame, 8 to a byte.
    static let samplesPerChannel = 37_632
    static let bytesPerChannel = 4_704
    /// A frame whose output matches up to its last `tailBytes` bytes per channel has lost its final samples.
    static let tailBytes = 16

    struct FixtureUnavailable: Error, CustomStringConvertible {
        var description: String
    }

    /// The named fixture; throws (failing every requirement of the check) when the fixture set lacks it or it is
    /// inconsistent with DST-001.
    static func fixture(_ name: String) throws -> DSTFixture {
        let all = DSTFixtures.all
        guard let f = all.first(where: { $0.name == name }) else {
            throw FixtureUnavailable(description: "fixture \(name) is missing (the fixture set has \(all.count) frames)")
        }
        guard [2, 5, 6].contains(f.channels), f.expected.count == f.channels * bytesPerChannel, !f.frame.isEmpty else {
            throw FixtureUnavailable(description: "fixture \(name) is inconsistent: \(f.channels) channels, "
                + "\(f.expected.count) expected bytes, \(f.frame.count) frame bytes")
        }
        return f
    }

    // MARK: Checks

    static func checkFixture(_ name: String, _ maker: any DSTDecoderMaker, _ checker: Checker) throws {
        let f = try fixture(name)
        let out = maker.makeDecoder(channels: f.channels).decode(frame: f.frame)
        verify(out, f, name, checker)
        // DST-004, channel by channel: every channel's DSD comes back exactly.
        guard let out else { return }
        for c in 0..<f.channels {
            let got = channelStream(out, channel: c, channels: f.channels)
            let want = channelStream(f.expected, channel: c, channels: f.channels)
            checker.expect(got == want, "DST-004",
                           "\(name): channel \(c + 1) is not recovered exactly: \(difference(got, want, channels: 1))")
        }
    }

    /// What every decode of a fixture frame must give, whatever was decoded before.
    static func verify(_ out: [UInt8]?, _ f: DSTFixture, _ context: String, _ checker: Checker) {
        let ch = f.channels
        let size = ch * bytesPerChannel
        if let out {
            // DST-001: 4 704 bytes per channel …
            checker.expect(out.count == size, "DST-001",
                           "\(context): decoded \(out.count) bytes; a \(ch)-channel frame is \(size) (4 704 per channel)")
            // … holding all 37 632 samples of each channel.
            if out.count == size {
                let first = firstMismatch(out, f.expected)
                let byteInChannel = first.map { $0 / ch } ?? bytesPerChannel
                checker.expect(first == nil || byteInChannel < bytesPerChannel - tailBytes, "DST-001",
                               "\(context): output matches the DSD up to sample \(byteInChannel * 8) of channel "
                               + "\((first ?? 0) % ch + 1) and differs only in the frame's last \(tailBytes * 8) samples "
                               + "per channel; a frame holds \(samplesPerChannel) samples per channel")
            }
            // DST-002: channel bytes interleaved in channel order, most significant bit oldest.
            let finding = layoutFinding(out, f.expected, channels: ch)
            checker.expect(finding == nil, "DST-002", "\(context): the output \(finding ?? "")")
        }
        // DST-003: byte for byte the reference decoder's output.
        checker.expect(out == f.expected, "DST-003",
                       "\(context): differs from the reference decoder's output: \(difference(out, f.expected, channels: ch))")
        // DST-004: exactly the DSD the frame was encoded from.
        checker.expect(out == f.expected, "DST-004",
                       "\(context): is not the DSD the frame encodes: \(difference(out, f.expected, channels: ch))")
    }

    /// DST-001 for a frame whose decoding is left open: nil, or a frame of 4 704 bytes per channel.
    static func expectFrameSize(_ out: [UInt8]?, channels: Int, _ context: String, _ checker: Checker) {
        let size = channels * bytesPerChannel
        checker.expect(out.map { $0.count == size } ?? true, "DST-001",
                       "\(context): decoded \(out?.count ?? 0) bytes; a decoded \(channels)-channel frame is \(size) "
                       + "(4 704 per channel), else the result is nil")
    }

    static func checkFrameSizes(_ frames: [(String, [UInt8])], channels: Int, _ maker: any DSTDecoderMaker,
                                _ checker: Checker) {
        for (label, frame) in frames {
            expectFrameSize(maker.makeDecoder(channels: channels).decode(frame: frame), channels: channels, label, checker)
        }
    }

    /// Stored (uncompressed) fixture frames cut short and extended, and the stored frames of the other channel
    /// counts, each given to a fresh decoder for the fixture's channel count.
    static func checkAlteredStored(_ name: String, others: [String], _ maker: any DSTDecoderMaker,
                                   _ checker: Checker) throws {
        let f = try fixture(name)
        let s = f.frame
        var frames: [(String, [UInt8])] = [
            ("empty frame", []),
            ("\(name) cut to its first byte", prefix(s, 1)),
            ("\(name) cut to its first two bytes", prefix(s, 2)),
            ("\(name) cut to half", prefix(s, s.count / 2)),
            ("\(name) without its last byte", droppingLast(s, 1)),
            ("\(name) with one byte appended", s + [0x00]),
            ("\(name) with 4 704 bytes appended", s + [UInt8](repeating: 0x69, count: bytesPerChannel)),
            ("\(name) with its DSD repeated", s + s.dropFirst()),
        ]
        for other in others {
            frames.append(("the \(other) frame", try fixture(other).frame))
        }
        checkFrameSizes(frames, channels: f.channels, maker, checker)
    }

    // MARK: Sequences

    enum Step {
        /// A fixture frame: must decode to its DSD.
        case fixture(DSTFixture)
        /// Any other bytes: the result is left open except for DST-001.
        case altered(String, [UInt8])
    }

    static func run(_ steps: [Step], on decoder: any DSTFrameDecoder, channels: Int, _ checker: Checker) {
        for (i, step) in steps.enumerated() {
            switch step {
            case .fixture(let f):
                verify(decoder.decode(frame: f.frame), f, "call \(i + 1) (\(f.name))", checker)
            case .altered(let label, let frame):
                expectFrameSize(decoder.decode(frame: frame), channels: channels, "call \(i + 1) (\(label))", checker)
            }
        }
    }

    // MARK: Layout (DST-002)

    /// Describes how `out` misplaces the frame's DSD, when it is recognisably that DSD in another layout: its bytes
    /// in other positions (planar, channels in another order, other interleaving), its bytes with the bit order
    /// reversed, the channels interleaved bit by bit, or one sample per byte. nil when `out` is the expected
    /// layout, or isn't the frame's DSD rearranged (wrong content is DST-003/DST-004, wrong size DST-001).
    static func layoutFinding(_ out: [UInt8], _ exp: [UInt8], channels ch: Int) -> String? {
        guard out != exp, ch > 0, !exp.isEmpty else { return nil }
        if out.count == exp.count {
            let want = histogram(exp)
            if histogram(out) == want {
                return "holds the frame's DSD bytes, but not each channel's bytes interleaved in channel order"
                    + arrangement(out, exp, channels: ch)
            }
            let reversed = out.map(reverseBits)
            if histogram(reversed) == want {
                return "holds the frame's DSD with the bit order of each byte reversed (least significant bit oldest)"
                    + (reversed == exp ? "" : arrangement(reversed, exp, channels: ch))
            }
            if ch > 1 && interleavedBySample(out, exp, channels: ch) {
                return "interleaves the channels one sample (bit) at a time instead of one byte at a time"
            }
            return nil
        }
        if out.count == exp.count * 8 {
            var values = Set<UInt8>()
            for b in out {
                values.insert(b)
                if values.count > 2 { break }
            }
            if values.count <= 2 {
                return "holds one sample per byte instead of 8 samples of a channel per byte"
            }
        }
        return nil
    }

    /// Where the channels ended up, for a message.
    static func arrangement(_ out: [UInt8], _ exp: [UInt8], channels ch: Int) -> String {
        guard out.count == exp.count, ch > 1 else { return "" }
        let n = exp.count / ch
        var planar = [UInt8]()
        planar.reserveCapacity(exp.count)
        for c in 0..<ch { planar += channelStream(exp, channel: c, channels: ch) }
        if out == planar { return " (the channels one after another, not interleaved)" }
        let wanted = (0..<ch).map { channelStream(exp, channel: $0, channels: ch) }
        var notes: [String] = []
        for slot in 0..<ch {
            let got = channelStream(out, channel: slot, channels: ch)
            if got == wanted[slot] { continue }
            if let other = wanted.firstIndex(of: got) {
                notes.append("position \(slot + 1) holds channel \(other + 1)")
            } else {
                notes.append("position \(slot + 1) holds no channel's bytes in order")
            }
        }
        return notes.isEmpty || n == 0 ? "" : " (" + notes.joined(separator: "; ") + ")"
    }

    /// True when `out`, read as one bit per sample with the channels interleaved sample by sample (most significant
    /// bit first), is exactly the expected DSD.
    static func interleavedBySample(_ out: [UInt8], _ exp: [UInt8], channels ch: Int) -> Bool {
        guard out.count == exp.count, exp.count % ch == 0 else { return false }
        let samples = exp.count / ch * 8
        for s in 0..<samples {
            for c in 0..<ch {
                let e = (exp[(s / 8) * ch + c] >> UInt8(7 - s % 8)) & 1
                let k = s * ch + c
                let o = (out[k / 8] >> UInt8(7 - k % 8)) & 1
                if e != o { return false }
            }
        }
        return true
    }

    // MARK: Byte helpers

    static func channelStream(_ bytes: [UInt8], channel c: Int, channels ch: Int) -> [UInt8] {
        guard ch > 0, c >= 0, c < ch else { return [] }
        var s = [UInt8]()
        s.reserveCapacity(bytes.count / ch + 1)
        var i = c
        while i < bytes.count {
            s.append(bytes[i])
            i += ch
        }
        return s
    }

    static func histogram(_ bytes: [UInt8]) -> [Int] {
        var h = [Int](repeating: 0, count: 256)
        for b in bytes { h[Int(b)] += 1 }
        return h
    }

    static func reverseBits(_ b: UInt8) -> UInt8 {
        var x = b, r: UInt8 = 0
        for _ in 0..<8 {
            r = (r << 1) | (x & 1)
            x >>= 1
        }
        return r
    }

    static func firstMismatch(_ a: [UInt8], _ b: [UInt8]) -> Int? {
        let n = min(a.count, b.count)
        for i in 0..<n where a[i] != b[i] { return i }
        return a.count == b.count ? nil : n
    }

    static func difference(_ out: [UInt8]?, _ exp: [UInt8], channels: Int) -> String {
        guard let out else { return "the decoder returned nil" }
        let ch = max(channels, 1)
        var differing = 0
        for i in 0..<min(out.count, exp.count) where out[i] != exp[i] { differing += 1 }
        var text = out.count == exp.count
            ? "\(differing) of \(exp.count) bytes differ"
            : "\(out.count) bytes instead of \(exp.count), \(differing) of the first \(min(out.count, exp.count)) differ"
        if let i = firstMismatch(out, exp), i < out.count, i < exp.count {
            text += "; first at byte \(i) (channel \(i % ch + 1), samples \(i / ch * 8)…\(i / ch * 8 + 7)): "
                + "got \(hex(out[i])), expected \(hex(exp[i]))"
        }
        return text
    }

    static func hex(_ b: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return "0x" + String(digits[Int(b >> 4)]) + String(digits[Int(b & 15)])
    }

    // MARK: Altered frames

    static func prefix(_ a: [UInt8], _ k: Int) -> [UInt8] {
        Array(a.prefix(max(0, k)))
    }

    static func droppingLast(_ a: [UInt8], _ k: Int) -> [UInt8] {
        Array(a.dropLast(max(0, k)))
    }
}
