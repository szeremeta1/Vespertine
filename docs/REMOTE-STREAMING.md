# Remote streaming (protocol 2): "Play on this phone"

The Mac's side of playing a song on the iPhone itself. Off by default, like everything in Settings › Remote. Design context:
`docs/plans/ios-spatial-multichannel.md` (multichannel and Spatial Audio on AirPods) and the iPhone plan (M2, M3).

## Turning it on

On the Mac: Settings › Remote › **Stream to Phones** (off by default; the remote server itself must be on). Each paired phone has its own
"May play songs from this Mac" checkbox, the section shows what each phone is playing, and the cache has a size choice and an Empty button.
A phone that asks while streaming is off, or that isn't allowed, gets a plain-words refusal in the Mac's language.

On the phone: Output › **This iPhone** (or This iPad). The Mac keeps doing whatever it was doing; choosing a Mac output again stops the phone.

## Versions

`RemoteProtocol.version` is 2; the oldest a Mac serves is 1. `hello` and `pair` keep their version-1 shape: `protocolVersion` is the
baseline (a v2 phone sends 1, so an old Mac accepts it) and the new optional `highestProtocolVersion` says what the phone speaks.
`RemoteProtocol.negotiate(baseline:highest:)` picks the connection's version; the Mac's `welcome` carries it in `ServerInfo.protocolVersion`
(`RemoteSession.canStream` on the phone). A version 1 phone is a remote exactly as before and never sees a stream frame.

## Commands

| Command | Answer |
|---|---|
| `streamInfo(ids, maxSampleRate)` | `.streamInfo([StreamInfo])`: per song, original or FLAC, the format that would arrive, or why it plays on the Mac only |
| `streamOpen(id, maxSampleRate, smaller?)` | `.streamOpened(StreamDescriptor)`, or `.streamPreparing(progress)` while the Mac converts (ask again), or `.failed(reason)`. `smaller: true` (a song kept on the phone in its smaller form) also converts a lossless file above `maxSampleRate` down to it |
| `streamRead(stream, offset, length)` | a **binary `StreamFrame`** carrying the command's `id`, or `.failed(reason)` |
| `streamClose(stream)` | `.ok` |

A phone names songs by library ID. No path ever comes from the network.

## The frame

A message on the wire is a 4-byte big-endian length and then the message. JSON messages start with `{`; a stream frame starts with `0x01`:
`0x01 | request id u32 | stream u32 | offset u64 | flags u8 (bit 0 = this range reaches the end) | payload`, big-endian. At most 1 MiB of payload
(`RemoteProtocol.maximumChunk`), inside the 4 MiB message limit. Reads are matched to their requests by id, so a phone keeps several in flight
(the Mac answers at most 8 at once, and each phone has up to four streams: the song playing, the next one, one being fetched to keep, and one
to spare while a song changes; opening a fifth closes the oldest).

## What is sent (`StreamPlanner`)

- **The original file's bytes** when Core Audio on the phone opens them: flac, m4a/mp4 (ALAC, AAC), wav, aiff, caf, mp3. A stereo file is never touched, even above the phone's rate.
- **A FLAC the Mac makes** (`FLACStreamTranscoder`, the player's own decoders) for DSD, APE, WavPack, TTA, Ogg, Opus, WMA, DTS, TrueHD/MLP, disc images,
  Matroska, CUE tracks (a file that is a whole album), FLAC above 24 bit, and a multichannel file above the phone's `maxSampleRate`.
  Every channel is kept (no fold), 16 bit stays 16, everything else is 24; the rate keeps its family (44.1 or 48 kHz), is never raised, and is
  capped by `maxSampleRate` (DSD: 192 kHz when the phone says nothing, so DSD64 becomes 176.4 kHz). PCM at the rate and depth asked for is bit-exact.
- **Not streamed**: more than 8 channels (FLAC's limit), or a kind of file nothing on the Mac converts. `macOnlyReason` says so.
- The speakers of each channel travel as Core Audio `AudioChannelLabel` values in `StreamFormat.channelLabels`; the phone builds its layout from them.

## Cache and safety

Conversions are cached in `~/Library/Caches/Vespertine/Remote/Streams` (8 GB, least recently used out first, never a file a phone is reading, kept across restarts
with a small metadata file beside each). One conversion runs at a time. The library files are only ever read. Opened files are closed with the connection.

## The phone's side (`VespertinePhonePlayer`)

- `PhoneQueue` (the Mac's queue rules), `PhonePlayback` (opens each song, prefetches the next, gapless when the formats match), `PhonePlayer`
  (AVAudioEngine; stereo untouched, surround onto a 7.1.4 bed through `AVAudioEnvironmentNode` for headphones, folded to stereo otherwise),
  `PhoneRemote` (takes the same `RemoteCommand`s the Mac does, so the screens don't care who plays) and `PhoneSystem` (lock screen, interruptions,
  route changes, the rate asked of a USB DAC).
- `StreamLine`: a stream outlives its connection. When the Mac stops answering, the phone waits (two minutes), opens the same song again and
  carries on at the same byte, as long as the tag and size are the same.
- `tracks(ids)` (new, additive): the songs for library IDs in the order asked, so the phone can build its own queue.
- `albums(offset, limit, sort?, filter?)`: the Mac sorts and narrows the Albums page before paging it. An older Mac ignores both.
- **Keep on This Device** (`KeptStore`, `Keeper`): an album or playlist is fetched whole, one song at a time, into Application Support (not backed
  up), listed and played with the Mac off. Lists are refreshed from the Mac at each connection. "Smaller copies" asks with `smaller: true`.
- The demo (`DemoSound`) serves generated sound through the same channel, so the app can be heard without a Mac.

## The listener's safety

The listener is reachable from wherever the Mac is (a tailnet, a forwarded port). `ConnectionThrottle`: a host that fails the handshake 10 times in
a minute is shut out for 5 minutes, and at most 16 connections may wait unsigned at once.

## Known limits

- Nothing here has been measured on hardware yet: see `docs/IOS-AUDIO-BENCH.md`. No claim of bit-perfect output or of Spatial Audio behaviour is
  made until those scripts have been run.
- More than 8 channels plays on the Mac only. DoP to a USB DAC from the phone is not built.
- Favorites and play counts made while offline are not sent back to the Mac.
- DSD→FLAC speed in a release build is unmeasured (debug: about 20 s of CPU per second of 5.1 DSD64 on a loaded machine).
- ReplayGain values are sent; gapless delay/padding are not (`encoderDelay`/`endPadding` are always nil).
