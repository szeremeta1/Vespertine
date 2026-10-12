# Brief: dop-stream, role C

You are one of several engineers working independently on the same interface contract. Others write tests,
implementations and broken variants of it separately; you will not see their work, and they will not see yours.
Your work is judged only through the contract.

## Rules

- Work only in your workspace, `/srv/cleanroom/dop-stream-C`. Do not read, list, search or open any path outside it (no `ls /`,
  no `find` outside the workspace, nothing under /home, /root, /tmp, /opt or /srv beyond your workspace), and don't
  try to find out what product or code this contract comes from. Don't use the network, web search, GitHub or any
  tool other than these: Read, Write and Edit on files inside the workspace, and Bash only in exactly this form:
  `swiftbox /srv/cleanroom/dop-stream-C "<command>"`. That runs `<command>` with Swift 6.2 on Linux in a sandbox that sees only
  your workspace, mounted at `/work` (the command starts in `/work`). Build with
  `swiftbox /srv/cleanroom/dop-stream-C "cd harness && swift build"`, and run your scratch program with
  `swiftbox /srv/cleanroom/dop-stream-C "cd harness && swift run Scratch"`.
- Your only sources are this brief: the contract, the requirement records, and the Swift API they compile against.
  If they leave something open, follow your role's instructions; don't guess at a hidden answer.
- Deliver:
- `/srv/cleanroom/dop-stream-C/harness/Sources/Mutants/DoPStreamMutants.swift` defining `public enum DoPStreamMutants { public static let all: [Mutant<any DoPStageMaker>] = [ … ] }`
  It must compile in Swift 6 language mode with `swiftbox /srv/cleanroom/dop-stream-C "cd harness && swift build"`, depend on
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

# Contract: DoP output stream

The last stage before the audio device while DoP is playing. Music (DoP sample values already packed) is written in; the device asks for frames out, one buffer at a time, and the stage must always deliver exactly as many as asked for.

## Values

Every value in and out is a 32-bit word holding one DoP sample **left-justified**: the 24-bit DoP sample in bits 31…8, bits 7…0 zero. So bits 31…24 are the marker byte and bits 23…8 the 16 DSD bits. Frames are interleaved: a frame is one word per channel, in channel order.

## Operations

```
makeStage(channels: Int, capacityFrames: Int) -> Stage
Stage.write(frames: [UInt32]) -> Int          // interleaved; returns how many whole frames were accepted
Stage.render(frameCount: Int) -> [UInt32]      // interleaved; always exactly frameCount × channels words
Stage.setMuted(Bool)
Stage.setGain(Double)                          // the stage's software gain control, linear (1.0 = unity)
Stage.setEqualizer(Bool)                       // turns on (true) or off a fixed equalizer setting that changes PCM
```

- `capacityFrames`: how many written frames the stage can hold before `write` accepts fewer than offered. At least `capacityFrames` frames are accepted into an empty stage.
- `write` takes whole frames only. The count of words passed is a multiple of `channels`. Written frames are played in the order written.
- `render` is called with any `frameCount` from 1 to 4096. A frame is played (consumed) when `render` returns it.
- `setMuted(true)`: while muted, the device must still be fed. `setMuted(false)` resumes.
- `setGain` and `setEqualizer` may be called at any time.

Music written by a caller is valid DoP: its own markers alternate frame to frame, and each frame's channels carry the same marker. Callers make no other promise; in particular, the first frame of a write does not necessarily continue the marker sequence of what the stage last played.

## Errors

None. `write` returns 0 when full. `render` never fails.

## The requirement records

```yaml
- id: DOPS-001
  kind: spec
  source:
    doc: 'DoP Open Standard: Method for transferring DSD Audio over PCM Frames'
    version: 1.1 (2012-03-30)
    section: §2 Solutions, page 2
    url: https://dsd-guide.com/sites/default/files/white-papers/DoP_openStandard_1v1.pdf
    availability: public
  requirement: Across everything the stage outputs (music and silence alike), the marker byte alternates between
    0x05 and 0xFA from each frame to the next, with no exception.
  quote: alternate with each sample between 0x05 and 0xFA
  testable: true
  gap: The standard describes the stream a DAC receives; it doesn't discuss pauses, track changes or a sender running
    out of data. This record applies the alternation to the whole output, whatever is being played.
- id: DOPS-002
  kind: spec
  source:
    doc: 'DoP Open Standard: Method for transferring DSD Audio over PCM Frames'
    version: 1.1 (2012-03-30)
    section: §4 Recommended implementation, page 3
    url: https://dsd-guide.com/sites/default/files/white-papers/DoP_openStandard_1v1.pdf
    availability: public
  requirement: A receiver leaves DSD mode on a single missing marker in any channel, so every output frame, on every
    channel, carries a valid marker, including while muted or when no music is available.
  quote: the receiver has to detect at least 1 single missing DSD marker byte in at least 1 channel.
  testable: true
  gap: §4 is the standard's recommended receiver behaviour, not a rule for senders; the sender requirement is derived
    from it. The claim it supports (the DAC stays in DSD through pauses and seeks) is the product's own.
- id: DOPS-003
  kind: spec
  source:
    doc: 'DSDIFF: Direct Stream Digital Interchange File Format'
    version: 1.5 (2004-04-27)
    section: §1.2 Definitions (Silence Pattern), page 5
    url: https://dsd-guide.com/sites/default/files/white-papers/DSDIFF_1.5_Spec.pdf
    availability: public
  requirement: 'Frames that carry no music carry DSD silence: within a run of such frames every DSD byte, on every
    channel, has the same value, and that value has four bits set and four clear.'
  quote: all Channel Bytes have the same value
  testable: true
  gap: DoP 1.1 doesn't say what to send when there is no music. This record uses DSDIFF's definition of DSD silence.
    It doesn't name the byte value (0x69, 0x96, 0x55 … all qualify), so a test may not require a particular one.
- id: DOPS-004
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: Every music frame written comes out bit-identical, in the order written, none dropped or repeated,
    while the stage keeps being rendered unmuted until it has played them.
  testable: true
- id: DOPS-005
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: 'Silence frames go out only where playback is held: while muted, or when no written music remains.
    One exception is allowed, see gap.'
  testable: true
  gap: The docs say silence is inserted only where playback is held. After a hold, the next music frame can carry
    the same marker as the last silence frame, and DOPS-001 then forces something in between. The docs don't cover
    this. This record allows at most one silence frame immediately before a music frame, and only where that music
    frame's marker equals the marker of the frame output just before it.
- id: DOPS-006
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: 'While muted, nothing written is consumed: after unmuting, the next music frame out is the first
    written frame that had not been output before the mute.'
  testable: true
- id: DOPS-007
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: 'A software gain other than 1.0, or the equalizer turned on, leaves DoP output unchanged: the same
    frames come out as with unity gain and no equalizer.'
  testable: true
  gap: the product documentation names the equalizer; that gain doesn't apply to DoP either is from the product
    documentation("DoP is always passthrough.").
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

### `harness/Sources/Contracts/DoPStream.swift`

```swift
//
// contracts/dop-stream.md in Swift. Says nothing the document doesn't.
// SPDX-License-Identifier: GPL-3.0-or-later
//

/// The last stage before the audio device while DoP plays. Every word holds one DoP sample left-justified: the
/// 24-bit DoP sample in bits 31…8 (marker byte in 31…24, DSD bits in 23…8), bits 7…0 zero. Frames are
/// interleaved, one word per channel, in channel order.
public protocol DoPStage: AnyObject {
    /// Interleaved whole frames (the word count is a multiple of `channels`). Returns how many frames were
    /// accepted; at least `capacityFrames` are accepted into an empty stage, and 0 when full.
    func write(frames: [UInt32]) -> Int
    /// Always exactly `frameCount × channels` words, `frameCount` from 1 to 4096. A frame is played (consumed)
    /// when `render` returns it.
    func render(frameCount: Int) -> [UInt32]
    /// While muted the device must still be fed.
    func setMuted(_ muted: Bool)
    /// The stage's software gain control, linear (1.0 is unity). May be called at any time.
    func setGain(_ gain: Double)
    /// Turns a fixed equalizer setting that changes PCM on or off. May be called at any time.
    func setEqualizer(_ on: Bool)
}

public protocol DoPStageMaker: Sendable {
    func makeStage(channels: Int, capacityFrames: Int) -> any DoPStage
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
