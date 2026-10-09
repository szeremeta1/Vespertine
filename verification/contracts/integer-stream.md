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
