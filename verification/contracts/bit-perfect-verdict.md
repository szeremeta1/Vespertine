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
| `integerMode` | Bool | the player is sending 32-bit integers straight to the device, with no 32-bit float step. Only ever true while the player holds the device exclusively (`readback.hogOwnerPID == readback.ownPID`; BPV-018): inputs with `integerMode` true and the device not held don't occur |

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
