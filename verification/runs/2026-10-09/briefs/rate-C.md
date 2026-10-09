# Brief: rate, role C

You are one of several engineers working independently on the same interface contract. Others write tests,
implementations and broken variants of it separately; you will not see their work, and they will not see yours.
Your work is judged only through the contract.

## Rules

- Work only in your workspace, `/srv/cleanroom/rate-C`. Do not read, list, search or open any path outside it (no `ls /`,
  no `find` outside the workspace, nothing under /home, /root, /tmp, /opt or /srv beyond your workspace), and don't
  try to find out what product or code this contract comes from. Don't use the network, web search, GitHub or any
  tool other than these: Read, Write and Edit on files inside the workspace, and Bash only in exactly this form:
  `swiftbox /srv/cleanroom/rate-C "<command>"`. That runs `<command>` with Swift 6.2 on Linux in a sandbox that sees only
  your workspace, mounted at `/work` (the command starts in `/work`). Build with
  `swiftbox /srv/cleanroom/rate-C "cd harness && swift build"`, and run your scratch program with
  `swiftbox /srv/cleanroom/rate-C "cd harness && swift run Scratch"`.
- Your only sources are this brief: the contract, the requirement records, and the Swift API they compile against.
  If they leave something open, follow your role's instructions; don't guess at a hidden answer.
- Deliver:
- `/srv/cleanroom/rate-C/harness/Sources/Mutants/RateMutants.swift` defining `public enum RateMutants { public static let all: [Mutant<any RatePlanner>] = [ … ] }`
  It must compile in Swift 6 language mode with `swiftbox /srv/cleanroom/rate-C "cd harness && swift build"`, depend on
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

# Contract: Device-rate choice and DoP planning

Pure functions that decide the rate an audio device is set to and whether DSD is sent as DoP.

## Signatures

```
chooseRate(sourceRate: Double, offeredRates: [Double], policy: Policy) -> Double
dopCarrierRate(dsdRate: Double) -> Double
planDSD(dsdRate: Double, device: DSDDevice) -> DSDPlan
```

## Types

- `Policy`: `matchSource`, `maximum`, or `fixed(rate: Double)`.
- `DSDDevice`:
  - `offeredRates: [Double]`: the nominal rates the device can be set to;
  - `dopEnabled: Bool`: the user marked the device as decoding DoP;
  - `integerBitDepths: [Int]`: bit depths of the integer physical formats the device offers at every one of its rates (for example `[16, 24, 32]`);
  - `channels: Int`: the device's output channel count.
- `DSDPlan`: `mode` (`dop` or `pcm`), `deviceRate: Double` (the rate the device is set to), and `pcmRate: Double?` (for `pcm`: the rate DSD is converted to before any further resampling; nil for `dop`).

## Inputs

- Rates are in hertz. `offeredRates` is non-empty, has no duplicates, and is in no particular order.
- `sourceRate` is a PCM sample rate. `dsdRate` is a DSD bit rate per channel (2 822 400 for DSD64, 5 644 800 for DSD128, …).
- `planDSD` is asked about a stereo DSD source.
- Two rates are equal when they differ by less than 0.5 Hz.

## Output

- `chooseRate` returns one of `offeredRates`, except for `fixed(rate)` when that rate is not offered (not specified).
- `planDSD.deviceRate` is one of `offeredRates`.

## Errors

None.

## The requirement records

```yaml
- id: RATE-001
  kind: spec
  source:
    doc: 'DoP Open Standard: Method for transferring DSD Audio over PCM Frames'
    version: 1.1 (2012-03-30)
    section: §2 Solutions, page 1
    url: https://dsd-guide.com/sites/default/files/white-papers/DoP_openStandard_1v1.pdf
    availability: public
  requirement: DSD at 2.8224 MHz (64FS) is carried as 24-bit PCM at 176.4 kHz.
  quote: The PCM format with the next higher bit rate is 24 bits at a sample rate of 176.4kHz.
  testable: true
- id: RATE-002
  kind: spec
  source:
    doc: 'DoP Open Standard: Method for transferring DSD Audio over PCM Frames'
    version: 1.1 (2012-03-30)
    section: §3 Solutions for double rate DSD (128FS) and beyond, page 2
    url: https://dsd-guide.com/sites/default/files/white-papers/DoP_openStandard_1v1.pdf
    availability: public
  requirement: 128FS DSD (5.6448 MHz) uses the same method with the PCM rate raised from 176.4 kHz to 352.8 kHz.
  quote: by simply raising the underlying PCM sample rate from 176.4kHz to 352.8kHz.
  testable: true
  gap: §3 also describes a second method (markers 0x06/0xF9 on a channel pair at 176.4 kHz) for links that can't
    run 352.8 kHz. The contract and the product use the first method only.
- id: RATE-003
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: The DoP carrier rate is the DSD rate divided by 16 at every DSD rate, so DSD256 (11.2896 MHz) runs
    at 705.6 kHz and DSD512 (22.5792 MHz) at 1411.2 kHz.
  testable: true
  gap: DoP 1.1 says only that the first method "can easily be extended" to higher DSD rates by raising the PCM rate;
    it names no rate above 352.8 kHz. The docs also say carrier rates above 384 kHz are untested on hardware.
- id: RATE-004
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: DoP is planned only when the device is marked as decoding DoP and offers the carrier rate. Otherwise
    DSD is converted to PCM at the DSD rate divided by 8.
  testable: true
  gap: After the conversion to PCM, the device rate follows the ordinary choice (RATE-006 to RATE-009) for that
    PCM rate.
- id: RATE-005
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: When the device is marked as decoding DoP and offers the carrier rate, DSD is planned as DoP at the
    carrier rate.
  testable: true
  gap: '"Supports the carrier rate" could also take in the bit depth: DoP needs 24-bit samples, and the docs don''t
    mention a device that offers the rate only at 16 bits. Tests should use devices that offer 24-bit or deeper
    integer formats.'
- id: RATE-006
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: With the match-source policy, when the device offers the source's rate, that rate is chosen.
  testable: true
- id: RATE-007
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: With the match-source policy, when the source rate isn't offered but an integer multiple of it is
    (twice, four times, …), an integer multiple is chosen.
  testable: true
  gap: '"Same rate family" is read as an integer multiple of the source rate, since the sentence lists higher rates
    and integer divisors after it. The docs don''t say which multiple when several are offered; tests may not require
    a particular one.'
- id: RATE-008
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: With the match-source policy, when neither the source rate nor an integer multiple is offered but
    some offered rate is higher than the source rate, a higher rate is chosen.
  testable: true
  gap: Which higher rate, when several are offered, isn't said; tests may not require a particular one.
- id: RATE-009
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: With the match-source policy, when every offered rate is lower than the source rate and some offered
    rate divides it exactly (half, a quarter, …), such an integer divisor is chosen.
  testable: true
  gap: Which divisor, when several are offered, isn't said. What happens when no offered rate is a multiple, higher,
    or a divisor isn't said either. Tests may not require either.
- id: RATE-010
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: With the maximum policy the highest offered rate is chosen, whatever the source rate. With a fixed
    rate that the device offers, that rate is chosen.
  testable: true
  gap: What a forced rate the device doesn't offer leads to isn't said; tests may not rely on it.
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

### `harness/Sources/Contracts/RatePlan.swift`

```swift
//
// contracts/rate-plan.md in Swift. Says nothing the document doesn't.
// SPDX-License-Identifier: GPL-3.0-or-later
//

public enum Policy: Sendable, Hashable {
    case matchSource
    case maximum
    case fixed(rate: Double)
}

public struct DSDDevice: Sendable, Hashable {
    /// The nominal rates the device can be set to (Hz): non-empty, no duplicates, in no particular order.
    public var offeredRates: [Double]
    /// The user marked the device as decoding DoP.
    public var dopEnabled: Bool
    /// Bit depths of the integer physical formats the device offers at every one of its rates, e.g. [16, 24, 32].
    public var integerBitDepths: [Int]
    /// The device's output channel count.
    public var channels: Int

    public init(offeredRates: [Double], dopEnabled: Bool, integerBitDepths: [Int], channels: Int) {
        self.offeredRates = offeredRates
        self.dopEnabled = dopEnabled
        self.integerBitDepths = integerBitDepths
        self.channels = channels
    }
}

public struct DSDPlan: Sendable, Hashable {
    public enum Mode: Sendable, Hashable { case dop, pcm }
    public var mode: Mode
    /// The rate the device is set to: one of the offered rates.
    public var deviceRate: Double
    /// For `pcm`, the rate DSD is converted to before any further resampling; nil for `dop`.
    public var pcmRate: Double?

    public init(mode: Mode, deviceRate: Double, pcmRate: Double?) {
        self.mode = mode
        self.deviceRate = deviceRate
        self.pcmRate = pcmRate
    }
}

/// Rates are in hertz; two rates are equal when they differ by less than 0.5 Hz.
public protocol RatePlanner: Sendable {
    /// Returns one of `offeredRates`, except for `fixed(rate)` when that rate isn't offered (not specified).
    func chooseRate(sourceRate: Double, offeredRates: [Double], policy: Policy) -> Double
    /// `dsdRate` is a DSD bit rate per channel (2 822 400 for DSD64).
    func dopCarrierRate(dsdRate: Double) -> Double
    /// For a stereo DSD source.
    func planDSD(dsdRate: Double, device: DSDDevice) -> DSDPlan
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
