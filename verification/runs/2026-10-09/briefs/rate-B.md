# Brief: rate, role B

You are one of several engineers working independently on the same interface contract. Others write tests,
implementations and broken variants of it separately; you will not see their work, and they will not see yours.
Your work is judged only through the contract.

## Rules

- Work only in your workspace, `/srv/cleanroom/rate-B`. Do not read, list, search or open any path outside it (no `ls /`,
  no `find` outside the workspace, nothing under /home, /root, /tmp, /opt or /srv beyond your workspace), and don't
  try to find out what product or code this contract comes from. Don't use the network, web search, GitHub or any
  tool other than these: Read, Write and Edit on files inside the workspace, and Bash only in exactly this form:
  `swiftbox /srv/cleanroom/rate-B "<command>"`. That runs `<command>` with Swift 6.2 on Linux in a sandbox that sees only
  your workspace, mounted at `/work` (the command starts in `/work`). Build with
  `swiftbox /srv/cleanroom/rate-B "cd harness && swift build"`, and run your scratch program with
  `swiftbox /srv/cleanroom/rate-B "cd harness && swift run Scratch"`.
- Your only sources are this brief: the contract, the requirement records, and the Swift API they compile against.
  If they leave something open, follow your role's instructions; don't guess at a hidden answer.
- Deliver:
- `/srv/cleanroom/rate-B/harness/Sources/CleanRoomB/BRate.swift` defining `public enum BRate { public static let subject: (any RatePlanner)? = <your implementation> }`
  It must compile in Swift 6 language mode with `swiftbox /srv/cleanroom/rate-B "cd harness && swift build"`, depend on
  nothing but the modules already in the workspace package, and not change any file you were given.
- Finish with a short report as your final message: what you delivered, every requirement or contract point you
  found ambiguous or contradictory (by ID), and every assumption you made.

## Your role: implementation (B)

Implement the contract so that every requirement record with `testable: true` holds.

- Where the contract and records leave a choice open, pick any behaviour consistent with them; don't add behaviour the contract doesn't ask for.
- Never trap for any input the contract allows; behave sensibly (no crash, no hang) for input it rules out.
- Don't deliver tests. You may try your code in `Sources/Scratch`; it is not delivered.

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
