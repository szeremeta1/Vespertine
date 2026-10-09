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
