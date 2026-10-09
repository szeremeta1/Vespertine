# Brief: dop-pack, role B

You are one of several engineers working independently on the same interface contract. Others write tests,
implementations and broken variants of it separately; you will not see their work, and they will not see yours.
Your work is judged only through the contract.

## Rules

- Work only in your workspace, `/srv/cleanroom/dop-pack-B`. Do not read, list, search or open any path outside it (no `ls /`,
  no `find` outside the workspace, nothing under /home, /root, /tmp, /opt or /srv beyond your workspace), and don't
  try to find out what product or code this contract comes from. Don't use the network, web search, GitHub or any
  tool other than these: Read, Write and Edit on files inside the workspace, and Bash only in exactly this form:
  `swiftbox /srv/cleanroom/dop-pack-B "<command>"`. That runs `<command>` with Swift 6.2 on Linux in a sandbox that sees only
  your workspace, mounted at `/work` (the command starts in `/work`). Build with
  `swiftbox /srv/cleanroom/dop-pack-B "cd harness && swift build"`, and run your scratch program with
  `swiftbox /srv/cleanroom/dop-pack-B "cd harness && swift run Scratch"`.
- Your only sources are this brief: the contract, the requirement records, and the Swift API they compile against.
  If they leave something open, follow your role's instructions; don't guess at a hidden answer.
- Deliver:
- `/srv/cleanroom/dop-pack-B/harness/Sources/CleanRoomB/BDoPPack.swift` defining `public enum BDoPPack { public static let subject: (any DoPPacker)? = <your implementation> }`
  It must compile in Swift 6 language mode with `swiftbox /srv/cleanroom/dop-pack-B "cd harness && swift build"`, depend on
  nothing but the modules already in the workspace package, and not change any file you were given.
- Finish with a short report as your final message: what you delivered, every requirement or contract point you
  found ambiguous or contradictory (by ID), and every assumption you made.

## Your role: implementation (B)

Implement the contract so that every requirement record with `testable: true` holds.

- Where the contract and records leave a choice open, pick any behaviour consistent with them; don't add behaviour the contract doesn't ask for.
- Never trap for any input the contract allows; behave sensibly (no crash, no hang) for input it rules out.
- Don't deliver tests. You may try your code in `Sources/Scratch`; it is not delivered.

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
