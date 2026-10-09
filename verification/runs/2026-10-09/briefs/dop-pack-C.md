# Brief: dop-pack, role C

You are one of several engineers working independently on the same interface contract. Others write tests,
implementations and broken variants of it separately; you will not see their work, and they will not see yours.
Your work is judged only through the contract.

## Rules

- Work only in your workspace, `/srv/cleanroom/dop-pack-C`. Do not read, list, search or open any path outside it (no `ls /`,
  no `find` outside the workspace, nothing under /home, /root, /tmp, /opt or /srv beyond your workspace), and don't
  try to find out what product or code this contract comes from. Don't use the network, web search, GitHub or any
  tool other than these: Read, Write and Edit on files inside the workspace, and Bash only in exactly this form:
  `swiftbox /srv/cleanroom/dop-pack-C "<command>"`. That runs `<command>` with Swift 6.2 on Linux in a sandbox that sees only
  your workspace, mounted at `/work` (the command starts in `/work`). Build with
  `swiftbox /srv/cleanroom/dop-pack-C "cd harness && swift build"`, and run your scratch program with
  `swiftbox /srv/cleanroom/dop-pack-C "cd harness && swift run Scratch"`.
- Your only sources are this brief: the contract, the requirement records, and the Swift API they compile against.
  If they leave something open, follow your role's instructions; don't guess at a hidden answer.
- Deliver:
- `/srv/cleanroom/dop-pack-C/harness/Sources/Mutants/DoPPackMutants.swift` defining `public enum DoPPackMutants { public static let all: [Mutant<any DoPPacker>] = [ … ] }`
  It must compile in Swift 6 language mode with `swiftbox /srv/cleanroom/dop-pack-C "cd harness && swift build"`, depend on
  nothing but the modules already in the workspace package, and not change any file you were given.
- Finish with a short report as your final message: what you delivered, every requirement or contract point you
  found ambiguous or contradictory (by ID), and every assumption you made.

## Your role: mutants (C)

Write deliberately wrong implementations ("mutants") that a good test suite for these requirements must catch.

- For every requirement ID with `testable: true`, write at least two mutants that each violate that requirement as written, while otherwise following the contract and, as far as possible, every other requirement. Range from blatant to subtle: wrong only at an edge, on one channel, after many frames, for one rate, on the second call, and so on. Each must be a real violation a thorough test of the record could detect: never something the record's `gap` leaves open, and never a difference no test could observe through the contract.
- Each mutant is a decorator over a correct implementation that the harness passes in at run time (you don't write that one): `Mutant("C-<REQ>-<letter>", targets: ["<REQ>"], summary: "<one line: what is wrong>") { base in <your wrapper around base> }`. `targets` lists every requirement the mutant violates (usually one).
- Mutants must never trap or hang, for any input the contract allows.
- You may write your own correct implementation in `Sources/Scratch` to try your mutants against; it is not delivered and nobody else sees it.

## The contract

# Contract: DoP packing

Packs DSD audio into DoP sample values.

## Signature

```
dopPack(dsd: [[UInt8]], firstMarker: UInt8) -> [[UInt32]]   throws InvalidInput
```

## Input

- `dsd`: one byte array per channel, in channel order. Every array has the same length, and that length is even.
- Each byte holds 8 consecutive DSD samples (bits) of its channel. The **most significant bit of a byte is the oldest** sample of the eight (the DSDIFF channel-byte convention). Bytes are in time order: byte `i + 1` follows byte `i`.
- `firstMarker`: the marker byte the first output sample carries. It is `0x05` or `0xFA`.

## Output

- One array per input channel, in the same channel order.
- Each element is one DoP sample: a 24-bit value in bits 23…0 of the `UInt32`. Bits 31…24 are zero.
- Element `j` of channel `c` is the DoP sample for sample period `j` of channel `c`.

## Errors

Throws `InvalidInput` when there are no channels, when the channel arrays differ in length, when a length is odd, or when `firstMarker` is neither `0x05` nor `0xFA`. An empty array per channel (length 0) is valid and returns empty arrays.

## State

None. Each call is independent.

## The requirement records

```yaml
- id: DOP-001
  kind: spec
  source:
    doc: 'DoP Open Standard: Method for transferring DSD Audio over PCM Frames'
    version: 1.1 (2012-03-30)
    section: §2 Solutions, page 2
    url: https://dsd-guide.com/sites/default/files/white-papers/DoP_openStandard_1v1.pdf
    availability: public
  requirement: Each DoP sample is a 24-bit value whose 8 most significant bits are the marker byte and whose 16
    least significant bits carry DSD data.
  quote: The 8 most significant bits are used for the DSD marker
  testable: true
- id: DOP-002
  kind: spec
  source:
    doc: 'DoP Open Standard: Method for transferring DSD Audio over PCM Frames'
    version: 1.1 (2012-03-30)
    section: §2 Solutions, page 2
    url: https://dsd-guide.com/sites/default/files/white-papers/DoP_openStandard_1v1.pdf
    availability: public
  requirement: The marker alternates from one sample period to the next between 0x05 and 0xFA.
  quote: alternate with each sample between 0x05 and 0xFA
  testable: true
  gap: The standard doesn't say which marker the first sample of a stream carries. The contract makes it an input
    (firstMarker).
- id: DOP-003
  kind: spec
  source:
    doc: 'DoP Open Standard: Method for transferring DSD Audio over PCM Frames'
    version: 1.1 (2012-03-30)
    section: §2 Solutions, page 2
    url: https://dsd-guide.com/sites/default/files/white-papers/DoP_openStandard_1v1.pdf
    availability: public
  requirement: Within one sample period, every channel's DoP sample carries the same marker.
  quote: Each channel within a sample contains the same marker.
  testable: true
- id: DOP-004
  kind: spec
  source:
    doc: 'DoP Open Standard: Method for transferring DSD Audio over PCM Frames'
    version: 1.1 (2012-03-30)
    section: §2 Solutions, page 2 (text and the 24-bit frame figure)
    url: https://dsd-guide.com/sites/default/files/white-papers/DoP_openStandard_1v1.pdf
    availability: public
  requirement: The 16 DSD bits of a channel's sample are that channel's next 16 DSD samples in time order, the oldest
    in slot t0, the most significant of the 16 bits (bit 15).
  quote: first or oldest bit in slot t0
  testable: true
  gap: The text says the oldest bit is in slot t0. That t0 is the most significant of the 16 DSD bits (t0 … t15
    from MSB to LSB) is shown only in the figure above that text, not stated in words.
- id: DOP-005
  kind: spec
  source:
    doc: 'DoP Open Standard: Method for transferring DSD Audio over PCM Frames'
    version: 1.1 (2012-03-30)
    section: §2 Solutions, page 2
    url: https://dsd-guide.com/sites/default/files/white-papers/DoP_openStandard_1v1.pdf
    availability: public
  requirement: Each channel's DoP samples carry only DSD data of that same channel.
  quote: each PCM Frame contains only DSD data corresponding to its assigned channel.
  testable: true
- id: DOP-006
  kind: spec
  source:
    doc: 'DSDIFF: Direct Stream Digital Interchange File Format'
    version: 1.5 (2004-04-27)
    section: §1.2 Definitions (Channel Byte), page 5; §3.3 DSD Sound Data Chunk, page 18
    url: https://dsd-guide.com/sites/default/files/white-papers/DSDIFF_1.5_Spec.pdf
    availability: public
  requirement: An input byte holds 8 consecutive DSD samples of one channel with the most significant bit the oldest,
    so the packer must read each byte from its most significant bit down.
  quote: the most significant bit is the oldest bit of the sequence
  testable: true
- id: DOP-007
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: 'Packing carries every DSD bit exactly once: per channel, the output has one sample per two input
    bytes, and no DSD bit is dropped, repeated, inverted or moved.'
  testable: true
```

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
