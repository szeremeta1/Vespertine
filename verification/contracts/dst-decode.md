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

`verification/fixtures/dst/` holds fifteen DST frames (2, 5 and 6 channels; twelve DST-coded and three stored uncompressed) with the DSD each one encodes, checked against an independent reference decoder (see `../requirements/dst.yaml`). In the harness, `DSTFixtures.all` loads them: each has a `name`, `channels`, `coding` (`"dst"` or `"uncompressed"`), the `frame` bytes and the `expected` output. They are the only DST frames available; nothing else may be assumed about the frame format.
