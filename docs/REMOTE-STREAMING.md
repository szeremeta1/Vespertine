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
| `streamOpen(id, maxSampleRate, smaller?, dop?)` | `.streamOpened(StreamDescriptor)`, or `.streamPreparing(progress)` while the Mac converts (ask again), or `.failed(reason)`. `smaller: true` (a song kept on the phone in its smaller form) also converts a lossless file above `maxSampleRate` down to it. `dop: 176400` (the highest DoP carrier rate the phone's DAC takes) has a two-channel DSD song sent as its own bits in DoP frames |
| `streamRead(stream, offset, length)` | a **binary `StreamFrame`** carrying the command's `id`, or `.failed(reason)` |
| `streamClose(stream)` | `.ok` |

A phone names songs by library ID. No path ever comes from the network.

Added since, all additive (no version bump; an older peer ignores or refuses them harmlessly):

- `ServerInfo.addresses`: where the Mac can be reached (its local addresses, its Tailscale address and name), sent in every `welcome`. The
  phone keeps them with the pairing (`SavedPairing.advertised`, at most 10) so it can find the Mac from another network without anything typed.
- `ping`: answered `.ok`. The phone sends it when the network changes or nothing has arrived for a while, to learn in 3 seconds rather than
  30 that the line is dead. An older Mac answers `.failed`, which proves the line just as well.
- `setLanguage(code)`: sent after `welcome`. The Mac then words its refusals ("Stream to Phones is off…") in the phone's language when it
  has it (`ReplyWords`), otherwise in its own.
- `StreamDescriptor.cut` and `.reduced`: `cut` is true when a conversion only cut a CUE track out of a lossless file (same rate, no bits
  dropped), so the phone says "cut on the Mac" rather than "converted". `reduced` is true when a song asked for in its smaller form was
  really brought down; a kept album shows SMALLER COPIES only when one of its songs was.
- `streamOpen`'s `dop` and `StreamDescriptor.dsdRate` (both optional, so an older Mac or phone never sees them): asked with `dop`, a
  two-channel DSD song whose carrier rate (a sixteenth of the DSD rate) is within it is not converted. Its own DSD bits are written as
  DoP 1.1 frames (marker 0x05/0xFA, then 16 bits) into a 24-bit FLAC at the carrier rate, which FLAC carries exactly, and the descriptor
  says `dsdRate` (2822400 for DSD64). The FLAC is a whole number of marker pairs long, so the next song's first marker carries on the
  alternation. Anything else (PCM, surround or mono DSD, a carrier above `dop`, a song kept in its smaller form) arrives as it would
  without `dop`. An older Mac ignores `dop` and sends PCM with no `dsdRate`, which the phone plays as PCM.
- `ServerMessage.streamsClosed(reason)`: sent when Stream to Phones, or this phone's own permission, is turned off. The phone stops what
  it plays from the Mac at once, the song it had fetched ahead included, and removes its stream files; songs kept on the phone play on.
  Only sent to a connection on protocol 2; an older phone would pass over it anyway.
- `ServerInfo.portable` and the Bonjour TXT key `nb`: the Mac is a notebook, so the phone pictures it as one.
- Hi-Res in the album filter means 88.2 kHz and up (`AlbumFilter.countsAsHiRes`), as the Hi-Res smart playlist does.
- `albumTracks` lists an album whole when its "copies" have no song in common (a stereo album with one surround song is not two copies).

## Finding the Mac (`RemoteSession`)

If the listener is up but Bonjour has announced it nowhere after 8 seconds (`AdvertisingWatch`; macOS keeps an app off the local network
until it is allowed under Privacy & Security › Local Network), Settings › Remote says so and the log has a line under category `remote`.

The listener and its Bonjour service are made in one place (`RemoteTransport.listener`). `RemoteAdvertisingTests` checks what the
listener is given, and, with `VESPERTINE_BONJOUR=1`, starts it and waits for Bonjour to take the service and for a browser made like the
phone's to see it (CI does not set it: the test needs Bonjour and a process macOS allows on the local network). To tell "the code does not
announce" from "this build is not allowed" on a Mac where a phone finds nothing:

```
VESPERTINE_BONJOUR=1 swift test --package-path Packages/VespertineRemoteKit --filter RemoteAdvertising
dns-sd -B _vespertine._tcp local.
log show --last 10m --predicate 'category == "remote"' | grep -i 'waiting\|announced'
```

If the test passes from Terminal while the app is not listed by `dns-sd`, the app's copy is being kept off the local network: every
build with its own bundle identifier (a test build, say) is asked about and allowed separately under Privacy & Security › Local Network,
and a copy started where nobody can answer that question (over SSH, from a script) may never be allowed. When Bonjour's refusal reaches
the listener it is a DNS-SD error (`PolicyDenied`, -65570), and the log line "The remote listener is waiting" carries it. A refused
build has not been observed with this log line yet; an allowed build and this test do announce.

Once paired, the phone tries every way it knows at once: Bonjour on this network, the address it last used, each advertised address, and a
typed one if there is one. Nearby routes start first (others wait 150 to 350 ms, or less if everything ahead of them has failed), the first
to finish the handshake wins and the rest are closed. The same key signs in on every route. `RemoteSession.reach` says which kind won
(this network, Tailscale, elsewhere), which the app shows as the route. It stays on a working route until that route breaks: it does not
move back to Wi-Fi on its own while a cellular line still answers.

When the network changes, or the system says the connection is no longer viable, the phone pings; no answer in 3 seconds and it reconnects
at once by whatever route now works. A song being played carries on from its buffer and its stream is reopened at the same byte
(`StreamLine`). Opening a song while disconnected waits up to 20 seconds for the Mac rather than failing. When nothing answers, the phone
says the likeliest reason (`ReachTrouble`: no network, Mac not on this network and no way from away, Tailscale off, or Mac not answering).

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

Conversions are cached in `~/Library/Caches/Vespertine/Remote/Streams` (a build with another bundle identifier uses its identifier in place of `Vespertine`, and a run with `-VespertineDataDirectory` keeps them in `Remote Streams` inside that directory, so app copies never share them; 8 GB, least recently used out first, never a file a phone is reading, kept across restarts
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
- **An external DAC** (`RateLadder`, `PhoneRoute`): the phone asks iOS to run the output at the song's rate, reads back what it got a moment
  later, and if iOS declined asks for half, and half again (352.8 → 176.4 → 88.2 → 44.1), so any conversion left to iOS is the simplest one.
  A surround song on an interface or HDMI receiver with more than two outputs asks for that many channels and sends each channel to an output
  of its own, unmixed; on a stereo output it is folded. The Output screen's "What Reaches the Output" lists what was read back: the song,
  the output's rate and channels, whether iOS resamples, and the volume. The engine applies no gain unless ReplayGain is turned on
  (below). A DAC, headphones or AirPlay giving way
  to the phone's speaker pauses; playback is never carried on from the speaker.
- **DSD on that DAC** (`PhoneDoP.swift`, `DoPProbe`): DSD is sent as DoP only to a DAC that passed a listening test on this phone. The test
  (Output › Play DSD natively? › Test DoP) plays five seconds of DSD64 made on the phone, a soft chord, as DoP at 176.4 kHz and asks
  "music or hiss?". A DAC can only play the chord if every frame reached it as sent, so "music" is the evidence; nothing is taken from the
  DAC's name. The answer is kept by iOS's identifier for the output (`DoPDACs`). Nothing is saved unless the sound went out to the same
  stereo USB output at 176.4 kHz with the volume at 100% from start to end. After "music", `PhonePlayback` asks for DSD with `dop`, and
  before a DoP song starts it has iOS bring the output to the carrier rate and reads back that it did (`DoPOutput.bring`); if not, the song
  is asked for again as PCM and that rate is not tried on that DAC again. A song lined up behind another comes as DoP only at the rate the
  output already runs at, so nothing changes under the song being heard. If the volume leaves 100%, or the output or its rate changes
  mid-song, the song is asked for again as PCM and carries on from where it was (`PhonePlayback.outputChanged`). The badge says
  NATIVE DSD · DoP only for such a stream on such a DAC.
- **ReplayGain** (`PhoneReplayGain`, Output › ReplayGain: Off, Track, Album; off until chosen). Off, no sample is changed and the Mac is
  asked nothing about gains: a test renders a song through the player and compares it with the decoded file, sample for sample. On, the
  phone asks for the song's values (`streamInfo`, which every Mac that can send songs answers) and multiplies its samples by the gain
  they give, by the Mac's rules: the chosen kind, or the other when the file has only that; never so much that the file's stated peak
  would pass full scale; kept between -30 and +15 dB. There is no preamp. Each song carries its own gain to the sample where it starts,
  so a gapless join between songs with different gains changes level exactly there. DSD sent as DoP is never scaled (the frames are
  DSD bits). A song with no values plays as it is. "What Reaches the Output" lists `ReplayGain: −6.2 dB` (or that the song has none)
  while it is on, and `PhoneSignal.processed` is true whenever the samples are changed, for the badge to go by. A kept song's values
  are kept with it, so it is levelled the same with the Mac off. On a share the values are read from the file's own tags when the
  song is played (`docs/PHONE-SHARES.md`). The level is not measured here: a file without ReplayGain tags is never analysed on the phone.

## The listener's safety

The listener is reachable from wherever the Mac is (a tailnet, a forwarded port). `ConnectionThrottle`: a host that fails the handshake 10 times in
a minute is shut out for 5 minutes, and at most 16 connections may wait unsigned at once. A failure within 10 seconds of the same host
signing in is not counted, since a phone trying every route at once hangs up on the slower ones.

## Known limits

- Nothing here has been measured on hardware yet: see `docs/IOS-AUDIO-BENCH.md`. No claim of bit-perfect output or of Spatial Audio behaviour is
  made until those scripts have been run.
- More than 8 channels plays on the Mac only.
- DoP from the phone has not been run on a DAC yet (bench B8): whether iOS grants 176.4 kHz to a given DAC before a song starts, and
  whether its volume at 100% leaves samples untouched, are exactly what the listening test finds out per DAC. Surround and mono DSD are
  always PCM. A DSD song lined up behind a PCM song at another rate plays as PCM; started on its own, it plays as DoP.
- Favorites and play counts made while offline are not sent back to the Mac.
- Finding the Mac from away and moving between networks are covered by unit tests against a fake Mac only; B9 and B10 are not run.
- DSD→FLAC speed in a release build is unmeasured (debug: about 20 s of CPU per second of 5.1 DSD64 on a loaded machine).
- ReplayGain values are sent; gapless delay/padding are not (`encoderDelay`/`endPadding` are always nil).
