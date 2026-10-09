# Brief: verdict, role B2

You are one of several engineers working independently on the same interface contract. Others write tests,
implementations and broken variants of it separately; you will not see their work, and they will not see yours.
Your work is judged only through the contract.

## Rules

- Work only in your workspace, `/srv/cleanroom/verdict-B2`. Do not read, list, search or open any path outside it (no `ls /`,
  no `find` outside the workspace, nothing under /home, /root, /tmp, /opt or /srv beyond your workspace), and don't
  try to find out what product or code this contract comes from. Don't use the network, web search, GitHub or any
  tool other than these: Read, Write and Edit on files inside the workspace, and Bash only in exactly this form:
  `swiftbox /srv/cleanroom/verdict-B2 "<command>"`. That runs `<command>` with Swift 6.2 on Linux in a sandbox that sees only
  your workspace, mounted at `/work` (the command starts in `/work`). Build with
  `swiftbox /srv/cleanroom/verdict-B2 "cd harness && swift build"`, and run your scratch program with
  `swiftbox /srv/cleanroom/verdict-B2 "cd harness && swift run Scratch"`.
- Your only sources are this brief: the contract, the requirement records, and the Swift API they compile against.
  If they leave something open, follow your role's instructions; don't guess at a hidden answer.
- Deliver:
- `/srv/cleanroom/verdict-B2/harness/Sources/CleanRoomB2/B2Verdict.swift` defining `public enum B2Verdict { public static let subject: (any BadgeVerdict)? = <your implementation> }`
  It must compile in Swift 6 language mode with `swiftbox /srv/cleanroom/verdict-B2 "cd harness && swift build"`, depend on
  nothing but the modules already in the workspace package, and not change any file you were given.
- Finish with a short report as your final message: what you delivered, every requirement or contract point you
  found ambiguous or contradictory (by ID), and every assumption you made.

## Your role: implementation (B2)

Implement the contract so that every requirement record with `testable: true` holds.

- Where the contract and records leave a choice open, pick any behaviour consistent with them; don't add behaviour the contract doesn't ask for.
- Never trap for any input the contract allows; behave sensibly (no crash, no hang) for input it rules out.
- Don't deliver tests. You may try your code in `Sources/Scratch`; it is not delivered.

## The contract

# Contract: BIT-PERFECT verdict

A pure function from what a music player knows about one playing track to the one-line badge it shows. The badge is the product's own definition (see the `BPV-*` records); no external standard governs it.

## Signature

```
verdict(input: VerdictInput) -> String
```

## Input

`VerdictInput` has five parts.

**source**: the file being played.

| Field | Type | Meaning |
|---|---|---|
| `encoding` | `pcm`, `lossy` or `dsd` | `pcm` is lossless PCM (FLAC, ALAC, WAV, …); `lossy` is MP3, AAC, …; `dsd` is DSF or DSDIFF |
| `codec` | String | e.g. `"FLAC"`, `"AC3"`, `"DTS"` |
| `sampleRate` | Double | Hz; for DSD the 1-bit rate |
| `bitDepth` | Int? | bits per sample for integer PCM; nil when the file doesn't have one (lossy, float, DSD) |
| `channels` | Int | channels in the file |

**plan**: what the player set out to do.

| Field | Type | Meaning |
|---|---|---|
| `mode` | `pcm`, `dop` or `bitstream` | `dop`: DSD sent as DoP; `bitstream`: Dolby/DTS frames sent for a receiver to decode |
| `requestedRate` | Double | the device rate the player asked for (Hz) |
| `requestedBitDepth` | Int | the physical bit depth the player asked for |
| `channels` | Int | channels the player sends to the device |
| `resampling` | Bool | the player converts the sample rate |
| `dsdConvertedToPCM` | Bool | DSD is converted to PCM |
| `spatial` | `off`, `fixed` or `headTracked` | spatial audio rendering |
| `integerMode` | Bool | the player is sending 32-bit integers straight to the device, with no 32-bit float step |

**readback**: what the operating system reported about the device after the player configured it. A field is nil when reading it failed.

| Field | Type | Meaning |
|---|---|---|
| `nominalRate` | Double? | the device's current nominal sample rate (Hz) |
| `physicalBitDepth` | Int? | bits per sample of the device's physical format |
| `physicalIsInteger` | Bool? | whether that physical format is integer (false: floating point) |
| `deviceChannels` | Int | channels the device's output streams carry |
| `hogOwnerPID` | Int32? | the process that owns the device exclusively (hog mode), or −1 when no process does |
| `ownPID` | Int32 | the player's own process ID |

**device**: the class of output device.

`deviceClass` is one of: `usbDAC`, `builtInHeadphones` (the headphone jack), `builtInSpeakers` (the computer's own speakers), `bluetooth`, `airPlay`, `virtual`, `aggregate`, `airPodsMaxUSBC` (AirPods Max with the USB-C cable connected), `airPodsMaxBluetooth`, `other` (HDMI, DisplayPort, …).

**processing**: what else touches the samples.

| Field | Type | Meaning |
|---|---|---|
| `volume` | `hardware`, `fixed` or `digital(dB: Double)` | where volume is controlled; `digital` is the player's software volume |
| `replayGainDB` | Double? | ReplayGain applied, nil when off |
| `equalizerActive` | Bool | an equalizer preset that changes samples is applied |
| `otherAppsPlaying` | Bool | another process is currently playing to the same device |
| `concealedFrames` | Int | frames of this track the decoder replaced with silence because the file is damaged there |

## Output

The badge, a String. Strings the records name: `"BIT-PERFECT"`, `"NATIVE DSD · DoP"` (the middle character is U+00B7 MIDDLE DOT, with a space on each side), strings that start with `"BITSTREAM · "`, `"EQUALIZER"` and `"DAMAGED FRAMES SILENCED"`. Any other string is a reason the path isn't bit-perfect.

## Errors

None.

## The requirement records

```yaml
- id: BPV-001
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: In PCM mode the badge is not BIT-PERFECT when the source is lossy or DSD, when the rate is converted,
    or when DSD is converted to PCM.
  testable: true
  gap: the product documentationsays the source must be lossless; the contract's `pcm` encoding means lossless PCM.
- id: BPV-002
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: In PCM mode the badge is not BIT-PERFECT unless the nominal rate read back from the device equals
    the source's sample rate. The requested rate doesn't count.
  testable: true
  gap: The docs don't give a tolerance. The contract treats rates within 0.5 Hz as equal; tests should use rates
    that clearly differ.
- id: BPV-003
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: 'When the nominal rate or the physical format could not be read back, the badge is not BIT-PERFECT,
    NATIVE DSD · DoP or BITSTREAM: an unconfirmed format is not trusted.'
  testable: true
  gap: The docs say the app doesn't trust its own request; they don't describe a failed readback. This record reads
    the sentence as covering it.
- id: BPV-004
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: In PCM mode the badge is not BIT-PERFECT when an integer physical format has fewer bits than the
    source, or when a floating-point physical format has fewer than 32 bits.
  testable: true
  gap: A source with no bit depth (float or lossy files) isn't covered by the docs; tests shouldn't depend on it.
- id: BPV-005
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: In PCM mode a source deeper than 24 bits is BIT-PERFECT only with integer mode in effect; without
    it, the badge is not BIT-PERFECT.
  testable: true
- id: BPV-006
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: The badge is not BIT-PERFECT, NATIVE DSD · DoP or BITSTREAM while digital volume or ReplayGain applies
    any gain other than exactly 0 dB. Hardware or fixed volume, and digital volume or ReplayGain at 0 dB, are allowed.
  testable: true
  gap: That the gain conditions also apply to DoP and bitstream is from the product documentation(the conditions
    every bit-perfect path meets).
- id: BPV-007
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: The badge is not BIT-PERFECT, NATIVE DSD · DoP or BITSTREAM when spatial audio is on, when the channels
    sent differ from the file's channels, or when the device carries fewer channels than the file.
  testable: true
- id: BPV-008
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: The badge is not BIT-PERFECT, NATIVE DSD · DoP or BITSTREAM when another app is playing to the device,
    unless the player holds the device exclusively.
  testable: true
- id: BPV-009
  kind: spec
  source:
    doc: Core Audio AudioHardware.h (macOS 27.0 SDK)
    version: SDK 27.0 (26A425), Xcode 27.0 (27A266a)
    section: kAudioDevicePropertyHogMode
    url: https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertyhogmode
    availability: public
  requirement: Holding the device exclusively means the hog-mode owner read back from the device is the player's
    own process ID; −1 means no process holds it. A request for exclusive access that didn't take effect doesn't
    count.
  quote: A pid_t indicating the process that currently owns exclusive access to the AudioDevice or a value of -1
  testable: true
- id: BPV-010
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: On a Bluetooth device (AirPods Max over Bluetooth included) or an AirPlay device the badge is never
    BIT-PERFECT, NATIVE DSD · DoP or BITSTREAM.
  testable: true
- id: BPV-011
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: On the computer's built-in speakers, a virtual device or an aggregate device the badge is never BIT-PERFECT.
  testable: true
  gap: The docs say BIT-PERFECT; they don't say whether NATIVE DSD · DoP or BITSTREAM could appear on these devices.
- id: BPV-012
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: 'AirPods Max with the USB-C cable connected can be bit-perfect: a 48 kHz file that meets every other
    condition gets BIT-PERFECT on them.'
  testable: true
  gap: The device reads back as 24-bit integer at 48 kHz in the docs' description; tests should use that readback.
- id: BPV-013
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: When any frame of the track was replaced with silence, the badge is "DAMAGED FRAMES SILENCED" and
    not BIT-PERFECT, NATIVE DSD · DoP or BITSTREAM.
  testable: true
  gap: The docs give this label for SACD images; they don't say whether another reason (spatial audio, a Bluetooth
    device) would be shown instead when both apply. Tests should change only the concealed-frame count.
- id: BPV-014
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: On a PCM path that would otherwise be BIT-PERFECT, an active equalizer preset makes the badge exactly
    "EQUALIZER".
  testable: true
  gap: When the equalizer is on and another condition also fails, the docs don't say which label wins; tests should
    change only the equalizer.
- id: BPV-015
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: A lossless PCM file at its own rate, on a device that can be bit-perfect, with every condition of
    BPV-001 to BPV-011 met and no frames concealed, gets exactly "BIT-PERFECT".
  testable: true
  gap: 'The docs state the conditions as necessary ("only when"). That meeting all of them gives the badge is read
    from this line: the badge says what changed only when a condition fails.'
- id: BPV-016
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: In DoP mode the badge is "NATIVE DSD · DoP" exactly when the nominal rate read back equals the planned
    carrier rate, the physical format has at least 24 bits, and BPV-006 to BPV-011 and BPV-013 hold.
  testable: true
  gap: The docs don't say whether the 24-bit physical format must be integer.
- id: BPV-017
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: In bitstream mode the badge starts "BITSTREAM · " only when the nominal rate read back equals the
    planned rate, the physical format is integer with at least 16 bits, and the shared conditions hold.
  testable: true
  gap: '"Exclusive" here describes the plan. Whether the badge also needs the device held exclusively, or accepts
    shared mode with no other app playing, isn''t said; tests should hold the device exclusively. The codec name
    after the dot isn''t specified.'
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

### `harness/Sources/Contracts/Verdict.swift`

```swift
//
// contracts/bit-perfect-verdict.md in Swift. Says nothing the document doesn't.
// SPDX-License-Identifier: GPL-3.0-or-later
//

/// What a music player knows about one playing track.
public struct VerdictInput: Sendable, Hashable {
    public enum Encoding: Sendable, Hashable { case pcm, lossy, dsd }
    public enum Mode: Sendable, Hashable { case pcm, dop, bitstream }
    public enum Spatial: Sendable, Hashable { case off, fixed, headTracked }
    public enum DeviceClass: Sendable, Hashable, CaseIterable {
        case usbDAC, builtInHeadphones, builtInSpeakers, bluetooth, airPlay, virtual, aggregate
        case airPodsMaxUSBC, airPodsMaxBluetooth, other
    }
    public enum Volume: Sendable, Hashable {
        case hardware
        case fixed
        case digital(dB: Double)
    }

    /// The file being played.
    public struct Source: Sendable, Hashable {
        /// `pcm` is lossless PCM (FLAC, ALAC, WAV, …); `lossy` is MP3, AAC, …; `dsd` is DSF or DSDIFF.
        public var encoding: Encoding
        /// e.g. "FLAC", "AC3", "DTS".
        public var codec: String
        /// Hz; for DSD the 1-bit rate.
        public var sampleRate: Double
        /// Bits per sample for integer PCM; nil when the file doesn't have one (lossy, float, DSD).
        public var bitDepth: Int?
        public var channels: Int

        public init(encoding: Encoding, codec: String, sampleRate: Double, bitDepth: Int?, channels: Int) {
            self.encoding = encoding
            self.codec = codec
            self.sampleRate = sampleRate
            self.bitDepth = bitDepth
            self.channels = channels
        }
    }

    /// What the player set out to do.
    public struct Plan: Sendable, Hashable {
        /// `dop`: DSD sent as DoP; `bitstream`: Dolby/DTS frames sent for a receiver to decode.
        public var mode: Mode
        /// The device rate the player asked for (Hz).
        public var requestedRate: Double
        /// The physical bit depth the player asked for.
        public var requestedBitDepth: Int
        /// Channels the player sends to the device.
        public var channels: Int
        /// The player converts the sample rate.
        public var resampling: Bool
        /// DSD is converted to PCM.
        public var dsdConvertedToPCM: Bool
        public var spatial: Spatial
        /// The player sends 32-bit integers straight to the device, with no 32-bit float step.
        public var integerMode: Bool

        public init(mode: Mode, requestedRate: Double, requestedBitDepth: Int, channels: Int, resampling: Bool,
                    dsdConvertedToPCM: Bool, spatial: Spatial, integerMode: Bool) {
            self.mode = mode
            self.requestedRate = requestedRate
            self.requestedBitDepth = requestedBitDepth
            self.channels = channels
            self.resampling = resampling
            self.dsdConvertedToPCM = dsdConvertedToPCM
            self.spatial = spatial
            self.integerMode = integerMode
        }
    }

    /// What the operating system reported about the device after the player configured it. A field is nil when
    /// reading it failed.
    public struct Readback: Sendable, Hashable {
        /// The device's current nominal sample rate (Hz).
        public var nominalRate: Double?
        /// Bits per sample of the device's physical format.
        public var physicalBitDepth: Int?
        /// Whether that physical format is integer (false: floating point).
        public var physicalIsInteger: Bool?
        /// Channels the device's output streams carry.
        public var deviceChannels: Int
        /// The process that owns the device exclusively (hog mode), or −1 when no process does.
        public var hogOwnerPID: Int32?
        /// The player's own process ID.
        public var ownPID: Int32

        public init(nominalRate: Double?, physicalBitDepth: Int?, physicalIsInteger: Bool?, deviceChannels: Int,
                    hogOwnerPID: Int32?, ownPID: Int32) {
            self.nominalRate = nominalRate
            self.physicalBitDepth = physicalBitDepth
            self.physicalIsInteger = physicalIsInteger
            self.deviceChannels = deviceChannels
            self.hogOwnerPID = hogOwnerPID
            self.ownPID = ownPID
        }
    }

    /// What else touches the samples.
    public struct Processing: Sendable, Hashable {
        /// Where volume is controlled; `digital` is the player's software volume.
        public var volume: Volume
        /// ReplayGain applied, nil when off.
        public var replayGainDB: Double?
        /// An equalizer preset that changes samples is applied.
        public var equalizerActive: Bool
        /// Another process is currently playing to the same device.
        public var otherAppsPlaying: Bool
        /// Frames of this track the decoder replaced with silence because the file is damaged there.
        public var concealedFrames: Int

        public init(volume: Volume, replayGainDB: Double?, equalizerActive: Bool, otherAppsPlaying: Bool, concealedFrames: Int) {
            self.volume = volume
            self.replayGainDB = replayGainDB
            self.equalizerActive = equalizerActive
            self.otherAppsPlaying = otherAppsPlaying
            self.concealedFrames = concealedFrames
        }
    }

    public var source: Source
    public var plan: Plan
    public var readback: Readback
    /// The class of output device: `builtInHeadphones` is the headphone jack, `builtInSpeakers` the computer's own
    /// speakers, `airPodsMaxUSBC` AirPods Max with the USB-C cable connected, `other` HDMI, DisplayPort, ….
    public var deviceClass: DeviceClass
    public var processing: Processing

    public init(source: Source, plan: Plan, readback: Readback, deviceClass: DeviceClass, processing: Processing) {
        self.source = source
        self.plan = plan
        self.readback = readback
        self.deviceClass = deviceClass
        self.processing = processing
    }
}

/// The strings the records name. Any other string is a reason the path isn't bit-perfect.
public enum Badge {
    public static let bitPerfect = "BIT-PERFECT"
    /// The middle character is U+00B7 MIDDLE DOT, with a space on each side.
    public static let nativeDoP = "NATIVE DSD \u{00B7} DoP"
    /// Bitstream badges start with this.
    public static let bitstreamPrefix = "BITSTREAM \u{00B7} "
    public static let equalizer = "EQUALIZER"
    public static let damagedFrames = "DAMAGED FRAMES SILENCED"
}

public protocol BadgeVerdict: Sendable {
    /// The one-line badge for one playing track.
    func verdict(_ input: VerdictInput) -> String
}
```
