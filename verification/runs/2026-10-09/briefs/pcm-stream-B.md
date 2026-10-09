# Brief: pcm-stream, role B

You are one of several engineers working independently on the same interface contract. Others write tests,
implementations and broken variants of it separately; you will not see their work, and they will not see yours.
Your work is judged only through the contract.

## Rules

- Work only in your workspace, `/srv/cleanroom/pcm-stream-B`. Do not read, list, search or open any path outside it (no `ls /`,
  no `find` outside the workspace, nothing under /home, /root, /tmp, /opt or /srv beyond your workspace), and don't
  try to find out what product or code this contract comes from. Don't use the network, web search, GitHub or any
  tool other than these: Read, Write and Edit on files inside the workspace, and Bash only in exactly this form:
  `swiftbox /srv/cleanroom/pcm-stream-B "<command>"`. That runs `<command>` with Swift 6.2 on Linux in a sandbox that sees only
  your workspace, mounted at `/work` (the command starts in `/work`). Build with
  `swiftbox /srv/cleanroom/pcm-stream-B "cd harness && swift build"`, and run your scratch program with
  `swiftbox /srv/cleanroom/pcm-stream-B "cd harness && swift run Scratch"`.
- Your only sources are this brief: the contract, the requirement records, and the Swift API they compile against.
  If they leave something open, follow your role's instructions; don't guess at a hidden answer.
- Deliver:
- `/srv/cleanroom/pcm-stream-B/harness/Sources/CleanRoomB/BFloat.swift` defining `public enum BFloat { public static let subject: (any FloatOutput)? = <your implementation> }`
- `/srv/cleanroom/pcm-stream-B/harness/Sources/CleanRoomB/BInteger.swift` defining `public enum BInteger { public static let subject: (any IntegerOutput)? = <your implementation> }`
  It must compile in Swift 6 language mode with `swiftbox /srv/cleanroom/pcm-stream-B "cd harness && swift build"`, depend on
  nothing but the modules already in the workspace package, and not change any file you were given.
- Finish with a short report as your final message: what you delivered, every requirement or contract point you
  found ambiguous or contradictory (by ID), and every assumption you made.

## Your role: implementation (B)

Implement the contract so that every requirement record with `testable: true` holds.

- Where the contract and records leave a choice open, pick any behaviour consistent with them; don't add behaviour the contract doesn't ask for.
- Never trap for any input the contract allows; behave sensibly (no crash, no hang) for input it rules out.
- Don't deliver tests. You may try your code in `Sources/Scratch`; it is not delivered.

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
