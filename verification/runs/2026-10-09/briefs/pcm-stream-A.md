# Brief: pcm-stream, role A

You are one of several engineers working independently on the same interface contract. Others write tests,
implementations and broken variants of it separately; you will not see their work, and they will not see yours.
Your work is judged only through the contract.

## Rules

- Work only in your workspace, `/srv/cleanroom/pcm-stream-A`. Do not read, list, search or open any path outside it (no `ls /`,
  no `find` outside the workspace, nothing under /home, /root, /tmp, /opt or /srv beyond your workspace), and don't
  try to find out what product or code this contract comes from. Don't use the network, web search, GitHub or any
  tool other than these: Read, Write and Edit on files inside the workspace, and Bash only in exactly this form:
  `swiftbox /srv/cleanroom/pcm-stream-A "<command>"`. That runs `<command>` with Swift 6.2 on Linux in a sandbox that sees only
  your workspace, mounted at `/work` (the command starts in `/work`). Build with
  `swiftbox /srv/cleanroom/pcm-stream-A "cd harness && swift build"`, and run your scratch program with
  `swiftbox /srv/cleanroom/pcm-stream-A "cd harness && swift run Scratch"`.
- Your only sources are this brief: the contract, the requirement records, and the Swift API they compile against.
  If they leave something open, follow your role's instructions; don't guess at a hidden answer.
- Deliver:
- `/srv/cleanroom/pcm-stream-A/harness/Sources/SpecChecks/FloatChecks.swift` defining `public enum FloatChecks { public static let all: [SpecCheck<any FloatOutput>] = [ … ] }`
- `/srv/cleanroom/pcm-stream-A/harness/Sources/SpecChecks/IntegerChecks.swift` defining `public enum IntegerChecks { public static let all: [SpecCheck<any IntegerOutput>] = [ … ] }`
  It must compile in Swift 6 language mode with `swiftbox /srv/cleanroom/pcm-stream-A "cd harness && swift build"`, depend on
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

# Contract: Float output stream at unity gain

The last stage before the audio device for ordinary PCM in 32-bit float, with no gain and no equalizer. Also the mapping from 24-bit integer samples into that float format.

## Values

Samples are IEEE 754 binary32 (`Float32`), exchanged as values, not bit patterns. Full scale is ±1.0. Frames are interleaved: one sample per channel, in channel order.

## Operations

```
int24ToFloat(samples: [Int32]) -> [Float32]   // each k in −8 388 608 … 8 388 607 (a signed 24-bit sample)
makeStage(channels: Int, capacityFrames: Int) -> Stage
Stage.write(samples: [Float32]) -> Int        // interleaved; returns how many whole frames were accepted
Stage.render(frameCount: Int) -> [Float32]     // interleaved; always exactly frameCount × channels samples
Stage.setMuted(Bool)
```

- `int24ToFloat` converts each sample in turn, in order; the result has one value per input. It uses the scale where 2^23 (8 388 608) is full scale: each result is meant to equal k ÷ 2^23. Inputs outside the 24-bit range are not tested. A call may take any number of samples, up to all 2^24 values at once.
- `capacityFrames`: at least that many written frames are accepted into an empty stage.
- `write` takes whole frames only, played in the order written.
- `render` is called with any `frameCount` from 1 to 4096. A frame is played (consumed) when `render` returns it.
- `setMuted(true)`: while muted, the device must still be fed. `setMuted(false)` resumes.
- The stage is always at unity gain with no equalizer. Inputs are finite values from −1.0 to +1.0.

## Errors

None. `write` returns 0 when full. `render` never fails.

---

# Contract: Integer-mode output stream

The last stage before an audio device that takes 32-bit integer samples directly.

## Values

Every value in and out is a 32-bit word, exchanged as its bit pattern (`UInt32`). The words are signed 32-bit integer PCM samples, but any 32-bit pattern can occur and must be accepted, including patterns that would be NaN, infinity or denormal if read as `Float32`. Frames are interleaved: one word per channel, in channel order.

## Operations

```
makeStage(channels: Int, capacityFrames: Int) -> Stage
Stage.write(words: [UInt32]) -> Int           // interleaved; returns how many whole frames were accepted
Stage.render(frameCount: Int) -> [UInt32]      // interleaved; always exactly frameCount × channels words
Stage.setMuted(Bool)
```

- `capacityFrames`: at least that many written frames are accepted into an empty stage.
- `write` takes whole frames only, played in the order written.
- `render` is called with any `frameCount` from 1 to 4096. A frame is played (consumed) when `render` returns it.
- `setMuted(true)`: while muted, the device must still be fed. `setMuted(false)` resumes.

## Errors

None. `write` returns 0 when full. `render` never fails.

## The requirement records

```yaml
- id: FLT-001
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: For every 24-bit sample value k, the Float32 k ÷ 2^23 written to the stage comes out with exactly
    the same value.
  testable: true
- id: FLT-002
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: 'At unity gain with no equalizer the stage is a straight copy: any finite Float32 sample from −1.0
    to +1.0, including values that need more than 24 significant bits, comes out with exactly the same value.'
  testable: true
  gap: '"Straight copy" would also cover NaN, infinities and values beyond ±1.0; the docs don''t mention them and
    the contract doesn''t send them.'
- id: FLT-003
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: 'Samples keep their channel and their order: frame n channel c in is frame n channel c out, nothing
    dropped or repeated, however writes and renders are sized.'
  testable: true
- id: FLT-004
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: 'Converting a 24-bit integer sample to Float32 is exact: int24ToFloat(k) equals k ÷ 2^23 for every
    24-bit k, so distinct samples stay distinct and k is recovered by multiplying by 2^23.'
  testable: true
  gap: The docs say "exactly" but not the scale. The contract fixes full scale at 2^23 (the only power-of-two scale
    that maps the 24-bit range into −1.0 … +1.0).
- id: FLT-005
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: While muted, or when no written samples remain, the stage outputs silence (every sample equal to
    zero) and consumes nothing; afterwards the next sample out is the next one not yet played.
  testable: true
- id: INT-001
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: Every 32-bit word written comes out with all 32 bits unchanged, including words whose bit pattern
    would be a NaN (signalling or quiet), an infinity, a negative zero or a denormal if read as Float32.
  testable: true
- id: INT-002
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: 'Words keep their channel and their order: frame n channel c in is frame n channel c out, nothing
    dropped or repeated, however writes and renders are sized.'
  testable: true
- id: INT-003
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: While muted, or when no written words remain, the stage outputs silence (words equal to zero) and
    consumes nothing; afterwards the next word out is the next one not yet played.
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

### `harness/Sources/Contracts/FloatStream.swift`

```swift
//
// contracts/float-stream.md in Swift. Says nothing the document doesn't.
// SPDX-License-Identifier: GPL-3.0-or-later
//

/// The last stage before the audio device for ordinary PCM in 32-bit float, at unity gain with no equalizer.
/// Samples are exchanged as values, full scale ±1.0, interleaved one per channel in channel order.
public protocol FloatStage: AnyObject {
    /// Interleaved whole frames. Returns how many frames were accepted; at least `capacityFrames` are accepted
    /// into an empty stage, and 0 when full. Inputs are finite values from −1.0 to +1.0.
    func write(samples: [Float]) -> Int
    /// Always exactly `frameCount × channels` samples, `frameCount` from 1 to 4096. A frame is played (consumed)
    /// when `render` returns it.
    func render(frameCount: Int) -> [Float]
    /// While muted the device must still be fed.
    func setMuted(_ muted: Bool)
}

public protocol FloatOutput: Sendable {
    /// Converts each signed 24-bit sample (−8 388 608 … 8 388 607) in order, one result per input; full scale is
    /// 2^23, so each result is meant to equal k ÷ 2^23. Any number of samples per call.
    func int24ToFloat(samples: [Int32]) -> [Float]
    func makeStage(channels: Int, capacityFrames: Int) -> any FloatStage
}
```

### `harness/Sources/Contracts/IntegerStream.swift`

```swift
//
// contracts/integer-stream.md in Swift. Says nothing the document doesn't.
// SPDX-License-Identifier: GPL-3.0-or-later
//

/// The last stage before an audio device that takes 32-bit integer samples directly. Words are exchanged as bit
/// patterns; any pattern can occur (including ones that would be NaN, infinity or denormal as Float32).
/// Frames are interleaved, one word per channel, in channel order.
public protocol IntegerStage: AnyObject {
    /// Interleaved whole frames. Returns how many frames were accepted; at least `capacityFrames` are accepted
    /// into an empty stage, and 0 when full.
    func write(words: [UInt32]) -> Int
    /// Always exactly `frameCount × channels` words, `frameCount` from 1 to 4096. A frame is played (consumed)
    /// when `render` returns it.
    func render(frameCount: Int) -> [UInt32]
    /// While muted the device must still be fed.
    func setMuted(_ muted: Bool)
}

public protocol IntegerOutput: Sendable {
    func makeStage(channels: Int, capacityFrames: Int) -> any IntegerStage
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
