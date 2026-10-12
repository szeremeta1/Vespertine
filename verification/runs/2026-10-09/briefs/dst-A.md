# Brief: dst, role A

You are one of several engineers working independently on the same interface contract. Others write tests,
implementations and broken variants of it separately; you will not see their work, and they will not see yours.
Your work is judged only through the contract.

## Rules

- Work only in your workspace, `/srv/cleanroom/dst-A`. Do not read, list, search or open any path outside it (no `ls /`,
  no `find` outside the workspace, nothing under /home, /root, /tmp, /opt or /srv beyond your workspace), and don't
  try to find out what product or code this contract comes from. Don't use the network, web search, GitHub or any
  tool other than these: Read, Write and Edit on files inside the workspace, and Bash only in exactly this form:
  `swiftbox /srv/cleanroom/dst-A "<command>"`. That runs `<command>` with Swift 6.2 on Linux in a sandbox that sees only
  your workspace, mounted at `/work` (the command starts in `/work`). Build with
  `swiftbox /srv/cleanroom/dst-A "cd harness && swift build"`, and run your scratch program with
  `swiftbox /srv/cleanroom/dst-A "cd harness && swift run Scratch"`.
- Your only sources are this brief: the contract, the requirement records, and the Swift API they compile against.
  If they leave something open, follow your role's instructions; don't guess at a hidden answer.
- Deliver:
- `/srv/cleanroom/dst-A/harness/Sources/SpecChecks/DSTChecks.swift` defining `public enum DSTChecks { public static let all: [SpecCheck<any DSTDecoderMaker>] = [ … ] }`
  It must compile in Swift 6 language mode with `swiftbox /srv/cleanroom/dst-A "cd harness && swift build"`, depend on
  nothing but the modules already in the workspace package, and not change any file you were given.
- Finish with a short report as your final message: what you delivered, every requirement or contract point you
  found ambiguous or contradictory (by ID), and every assumption you made.

## Your role: tests (A)

Write checks that decide whether an implementation of the contract meets the requirement records below.

- Cover every record with `testable: true`: at least one check per requirement ID, and as many as it takes to test the requirement thoroughly (edge cases, every channel, many sizes and sequences). An implementation that breaks a requirement in any way a careful reader of the record could foresee should fail a check.
- Every assertion is `checker.expect(condition, "<ID>", "<message>")`, naming the one requirement it checks. A check's `requirements:` lists exactly the IDs it asserts. Put a comment line `// REQ: <IDs>` directly above each check.
- Assert only what a requirement says. Nothing a record leaves open (read each `gap`), nothing the contract says without a requirement behind it, and no particular choice where the records allow several. Records with `testable: false` are not tested.
- Checks run against several implementations, including deliberately broken ones. They must never trap or hang: check counts before indexing, no force unwraps, no `fatalError`, bounded loops. Each check should finish within a few seconds in a debug build. Use a fresh object per scenario where the contract has state.
- Deterministic: no system randomness or clock. Write your own seeded generator if you want pseudo-random data.
- You have no implementation to run against. You may write one in `Sources/Scratch` to try your checks; it is not delivered and nobody else sees it.

## The contract

# Contract: DST frame decoding

Decodes one DST-compressed frame of Super Audio CD audio to the DSD it encodes.

## Signature

```
makeDecoder(channels: Int) -> Decoder
Decoder.decode(frame: [UInt8]) -> [UInt8]?      // nil: the frame could not be decoded
```

## Input

- `channels`: 2, 5 or 6.
- `frame`: the bytes of one DST frame, 1/75 s of audio at 64 × 44 100 Hz (DSD64). Frames are independent; a decoder may keep tables between calls but the result for a frame must not depend on earlier frames.

## Output

- On success, the frame's DSD as interleaved channel bytes: byte 0 is channel 1, byte 1 channel 2, …, then the next byte of channel 1, and so on, in the channel order of the source. Within a byte the most significant bit is the oldest sample.
- `nil` when the frame can't be decoded.

## Errors

Returned as `nil`. Which frames count as undecodable is defined by the DST specification (ISO/IEC 14496-3 subpart 10), which this harness does not have; tests don't rely on it.

## Test data

the fixture set holds fifteen DST frames (2, 5 and 6 channels; twelve DST-coded and three stored uncompressed) with the DSD each one encodes, checked against an independent reference decoder . In the harness, `DSTFixtures.all` loads them: each has a `name`, `channels`, `coding` (`"dst"` or `"uncompressed"`), the `frame` bytes and the `expected` output. They are the only DST frames available; nothing else may be assumed about the frame format.

## The requirement records

```yaml
- id: DST-001
  kind: spec
  source:
    doc: 'DSDIFF: Direct Stream Digital Interchange File Format'
    version: 1.5 (2004-04-27)
    section: §1.2 Definitions (Super Audio CD Frame), page 5
    url: https://dsd-guide.com/sites/default/files/white-papers/DSDIFF_1.5_Spec.pdf
    availability: public
  requirement: A Super Audio CD frame is 1/75 s; at 64 × 44.1 kHz it holds 37 632 DSD samples per channel, so a
    decoded frame is 4 704 bytes per channel.
  quote: At 64×fs a frame covers 37632 DSD samples per channel
  testable: true
- id: DST-002
  kind: spec
  source:
    doc: 'DSDIFF: Direct Stream Digital Interchange File Format'
    version: 1.5 (2004-04-27)
    section: §3.3 DSD Sound Data Chunk, page 18
    url: https://dsd-guide.com/sites/default/files/white-papers/DSDIFF_1.5_Spec.pdf
    availability: public
  requirement: Decoded DSD is laid out as channel bytes (8 samples of one channel, most significant bit oldest)
    interleaved one per channel in channel order.
  quote: channel bytes are interleaved in the order as identified in the Channels Chunk
  testable: true
  gap: DSDIFF describes its own files. That an SACD's DST frames decode to the same layout is from the Scarlet Book,
    which isn't public; DSDIFF refers to its section 5.6.
- id: DST-003
  kind: oracle
  source:
    doc: SACD Ripper libdstdec (the MPEG-4 Audio reference module for DST, by Philips, as distributed with sacd_extract)
    version: sacd-ripper commit a3d981c935c3224217e2842cd492f9351106c81e (2023-01-14)
    section: 'libs/libdstdec: dst_fram.c DST_FramDSTDecode'
    url: https://github.com/sacd-ripper/sacd-ripper
    availability: public
  requirement: For every DST frame in the fixtures, the decoder's output equals the reference decoder's output byte
    for byte.
  testable: true
  gap: An oracle is a second implementation, not the standard. The fixtures come from a small test encoder and exercise
    only the coding tools it uses (plain and Rice-coded tables, shared filters, half probability, stored frames);
    real discs are covered by hardware/SACD-ORACLE.md.
- id: DST-004
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: 'DST decoding is lossless: each fixture frame decodes to exactly the DSD it was encoded from.'
  testable: true
  gap: The expected DSD is the encoder's input, confirmed by the reference decoder (DST-003) when the fixtures were
    made.
- id: DST-005
  kind: spec
  source:
    doc: 'ISO/IEC 14496-3:2019 Information technology: Coding of audio-visual objects, Part 3: Audio'
    version: Edition 5 (2019-12)
    section: Subpart 10 (DST); clause numbers not seen
    url: https://www.iso.org/standard/76383.html
    availability: paywalled
  requirement: The DST decoding process (frame header, filter and probability tables, arithmetic decoding, prediction)
    and which frames are invalid.
  testable: false
  status: blocked-on-source
  gap: Not bought (CHF 227). Until then DST decoding rests on oracle evidence (DST-003, hardware/SACD-ORACLE.md).
- id: DST-006
  kind: spec
  source:
    doc: Super Audio CD System Description (Scarlet Book)
    version: 1.3 (2002), as referenced by DSDIFF 1.5
    section: not seen
    availability: not-public
  requirement: 'Disc layout: Master TOC and its copies, area TOCs, track lists, sector and audio-frame format.'
  testable: false
  status: blocked-on-source
  gap: Licensed only to SACD licensees; no purchase route. SACD image reading stays oracle evidence against sacd_extract
    (hardware/SACD-ORACLE.md).
```

The DST fixture set is in `fixtures/dst/` of your workspace (`DSTFixtures.all` loads it): `2ch-stored`, `2ch-v0`, `2ch-v1`, `2ch-v2`, `2ch-v3`, `2ch-v4`, `2ch-v5`, `5ch-stored`, `5ch-v0`, `5ch-v1`, `5ch-v2`, `6ch-stored`, `6ch-v0`, `6ch-v1`, `6ch-v2`. Each `<name>.dst` is a frame and `<name>.dsd` the DSD it encodes; `fixtures.json` lists channels and coding.

## The Swift API (already in your workspace)

### `harness/Sources/Contracts/DoPPack.swift`

```swift
//
// contracts/dop-pack.md in Swift. Says nothing the document doesn't.
// SPDX-License-Identifier: GPL-3.0-or-later
//

/// Thrown for input the contract rules out.
public struct InvalidInput: Error, Equatable, Sendable {
    public init() {}
}

/// Packs DSD audio into DoP sample values.
public protocol DoPPacker: Sendable {
    /// - Parameters:
    ///   - dsd: one byte array per channel, in channel order, all the same even length. Each byte holds 8
    ///     consecutive DSD samples of its channel, the most significant bit the oldest; bytes are in time order.
    ///   - firstMarker: the marker byte of the first output sample, `0x05` or `0xFA`.
    /// - Returns: one array per channel; element `j` is the DoP sample for sample period `j`, a 24-bit value in
    ///   bits 23…0 (bits 31…24 zero).
    /// - Throws: `InvalidInput` when there are no channels, the lengths differ or are odd, or `firstMarker` is
    ///   neither `0x05` nor `0xFA`. Empty channel arrays are valid.
    func dopPack(dsd: [[UInt8]], firstMarker: UInt8) throws -> [[UInt32]]
}
```

### `harness/Sources/Contracts/DSTDecode.swift`

```swift
//
// contracts/dst-decode.md in Swift. Says nothing the document doesn't.
// SPDX-License-Identifier: GPL-3.0-or-later
//

public protocol DSTFrameDecoder: AnyObject {
    /// Decodes one DST frame (1/75 s at 64 × 44 100 Hz). On success, the DSD as channel bytes interleaved in channel
    /// order (byte 0 channel 1, byte 1 channel 2, …), most significant bit oldest. nil when the frame can't be
    /// decoded. The result must not depend on frames decoded earlier.
    func decode(frame: [UInt8]) -> [UInt8]?
}

public protocol DSTDecoderMaker: Sendable {
    /// `channels`: 2, 5 or 6.
    func makeDecoder(channels: Int) -> any DSTFrameDecoder
}

/// One frame of verification/fixtures/dst/ and the DSD it encodes (checked against a reference decoder).
public struct DSTFixture: Sendable, Hashable {
    public var name: String
    public var channels: Int
    /// "dst" (DST-coded) or "uncompressed" (stored as it is).
    public var coding: String
    public var frame: [UInt8]
    public var expected: [UInt8]

    public init(name: String, channels: Int, coding: String, frame: [UInt8], expected: [UInt8]) {
        self.name = name
        self.channels = channels
        self.coding = coding
        self.frame = frame
        self.expected = expected
    }
}
```

### `harness/Sources/SpecKit/SpecKit.swift`

```swift
//
// the small kit spec-traced checks are written with.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A check is a function of the thing under test, not a test case: the same check runs against every
// implementation of the contract and against every mutant. Every assertion names the requirement it checks, so a
// failure says which requirement it was, and the registry checker can find every ID used.
// Checks must never trap (no force unwraps, no unchecked indexing): a subject that misbehaves must fail a check,
// not stop the run.

/// One failed assertion.
public struct CheckFailure: Sendable, Hashable, CustomStringConvertible {
    public var requirement: String
    public var message: String
    public var file: String
    public var line: Int

    public var description: String { "[\(requirement)] \(message) (\(file):\(line))" }
}

/// Collects a check's assertions.
public final class Checker {
    public private(set) var failures: [CheckFailure] = []
    /// How many assertions were made per requirement ID.
    public private(set) var assertions: [String: Int] = [:]
    /// Failures beyond this many are counted but not kept (a check over millions of samples stays small).
    public let keep: Int

    public init(keep: Int = 50) { self.keep = keep }

    public private(set) var failureCount = 0

    /// Asserts `condition` for `requirement` (a record ID such as "DOP-002").
    @discardableResult
    public func expect(_ condition: Bool, _ requirement: String, _ message: @autoclosure () -> String = "",
                       file: String = #fileID, line: Int = #line) -> Bool {
        assertions[requirement, default: 0] += 1
        if !condition {
            failureCount += 1
            if failures.count < keep {
                failures.append(CheckFailure(requirement: requirement, message: message(), file: file, line: line))
            }
        }
        return condition
    }

    /// Records a failure without a condition.
    public func fail(_ requirement: String, _ message: String, file: String = #fileID, line: Int = #line) {
        expect(false, requirement, message, file: file, line: line)
    }
}

/// A named check of one or more requirements against a subject of type `Subject`.
public struct SpecCheck<Subject>: Sendable, CustomStringConvertible {
    public var name: String
    /// Every requirement ID the check asserts.
    public var requirements: [String]
    public var body: @Sendable (Subject, Checker) throws -> Void

    public init(_ name: String, requirements: [String], body: @escaping @Sendable (Subject, Checker) throws -> Void) {
        self.name = name
        self.requirements = requirements
        self.body = body
    }

    public var description: String { "\(name) [\(requirements.joined(separator: ", "))]" }

    public func run(on subject: Subject) -> CheckResult {
        let checker = Checker()
        var thrown: String?
        do { try body(subject, checker) } catch { thrown = String(describing: error) }
        return CheckResult(check: name, requirements: requirements, failures: checker.failures,
                           failureCount: checker.failureCount, assertions: checker.assertions, thrown: thrown)
    }
}

public struct CheckResult: Sendable, Hashable {
    public var check: String
    public var requirements: [String]
    public var failures: [CheckFailure]
    public var failureCount: Int
    public var assertions: [String: Int]
    /// An error the check let escape (counts as a failure of every requirement it names).
    public var thrown: String?

    public var passed: Bool { failureCount == 0 && thrown == nil && !assertions.isEmpty }
    /// Requirement IDs with at least one failed assertion (all of the check's IDs when it threw).
    public var failedRequirements: Set<String> {
        thrown != nil ? Set(requirements) : Set(failures.map(\.requirement))
    }
}

/// A deliberately wrong variant of a correct subject, aimed at one or more requirements.
public struct Mutant<Subject>: Sendable, CustomStringConvertible {
    public var id: String
    /// The requirement IDs this mutant violates.
    public var targets: [String]
    public var summary: String
    /// Wraps a correct subject into the mutant.
    public var make: @Sendable (Subject) -> Subject

    public init(_ id: String, targets: [String], summary: String, make: @escaping @Sendable (Subject) -> Subject) {
        self.id = id
        self.targets = targets
        self.summary = summary
        self.make = make
    }

    public var description: String { "\(id) [\(targets.joined(separator: ", "))]" }
}
```

### `harness/Sources/SpecKit/DSTFixtures.swift`

```swift
//
// loads verification/fixtures/dst/.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Contracts
import Foundation

public enum DSTFixtures {
    private struct Entry: Decodable {
        var name: String
        var channels: Int
        var coding: String
    }

    /// The fixture directory: $VERIFICATION_FIXTURES/dst when set, else verification/fixtures/dst next to this
    /// package.
    public static var directory: URL {
        if let root = ProcessInfo.processInfo.environment["VERIFICATION_FIXTURES"] {
            return URL(fileURLWithPath: root).appendingPathComponent("dst")
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/dst")
    }

    /// Every fixture, in fixtures.json order. Empty when the directory can't be read (checks then fail on it).
    public static let all: [DSTFixture] = {
        let dir = directory
        guard let index = try? Data(contentsOf: dir.appendingPathComponent("fixtures.json")),
              let entries = try? JSONDecoder().decode([Entry].self, from: index) else { return [] }
        return entries.compactMap { e in
            guard let frame = try? Data(contentsOf: dir.appendingPathComponent(e.name + ".dst")),
                  let dsd = try? Data(contentsOf: dir.appendingPathComponent(e.name + ".dsd")) else { return nil }
            return DSTFixture(name: e.name, channels: e.channels, coding: e.coding, frame: [UInt8](frame), expected: [UInt8](dsd))
        }
    }()
}
```
