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
