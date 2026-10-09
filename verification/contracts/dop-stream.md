# Contract: DoP output stream

The last stage before the audio device while DoP is playing. Music (DoP sample values already packed) is written in; the device asks for frames out, one buffer at a time, and the stage must always deliver exactly as many as asked for.

## Values

Every value in and out is a 32-bit word holding one DoP sample **left-justified**: the 24-bit DoP sample in bits 31…8, bits 7…0 zero. So bits 31…24 are the marker byte and bits 23…8 the 16 DSD bits. Frames are interleaved: a frame is one word per channel, in channel order.

## Operations

```
makeStage(channels: Int, capacityFrames: Int) -> Stage
Stage.write(frames: [UInt32]) -> Int          // interleaved; returns how many whole frames were accepted
Stage.render(frameCount: Int) -> [UInt32]      // interleaved; always exactly frameCount × channels words
Stage.setMuted(Bool)
Stage.setGain(Double)                          // the stage's software gain control, linear (1.0 = unity)
Stage.setEqualizer(Bool)                       // turns on (true) or off a fixed equalizer setting that changes PCM
```

- `capacityFrames`: how many written frames the stage can hold before `write` accepts fewer than offered. At least `capacityFrames` frames are accepted into an empty stage.
- `write` takes whole frames only. The count of words passed is a multiple of `channels`. Written frames are played in the order written.
- `render` is called with any `frameCount` from 1 to 4096. A frame is played (consumed) when `render` returns it.
- `setMuted(true)`: while muted, the device must still be fed. `setMuted(false)` resumes.
- `setGain` and `setEqualizer` may be called at any time.

Music written by a caller is valid DoP: its own markers alternate frame to frame, and each frame's channels carry the same marker. Callers make no other promise; in particular, the first frame of a write does not necessarily continue the marker sequence of what the stage last played.

## Errors

None. `write` returns 0 when full. `render` never fails.
