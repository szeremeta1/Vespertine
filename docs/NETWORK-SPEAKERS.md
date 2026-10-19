# Network speakers: HomePod, HomeView and Sonos

Research and plan for playing Vespertine's library on Apple HomePod, HomePod mini, HomeView and Sonos speakers. None of this is in the app yet. It is post-1.0 work; the 1.0 freeze starts November 3, 2026.

The short version:
- None of these speakers can be bit-perfect, and none takes more than 48 kHz.
- AirPlay 2 can carry 24-bit / 48 kHz lossless stereo and 5.1/7.1 AAC surround, but which format a Mac sends is undocumented, and that decides how good the HomePod path can be.
- The documented way to get Atmos and surround out of HomePods is an Apple TV 4K.
- Sonos plays 24-bit / 48 kHz FLAC from a URL, lossless.

## What each speaker can take

Facts as of October 2026, with sources. "Not documented" means no source was found, not that it's impossible.

| | Way in from Vespertine | Best stereo quality | Above 48 kHz | Surround / spatial |
|---|---|---|---|---|
| HomePod, HomePod mini, HomePod mini 2, HomeView | AirPlay 2 from the Mac | AirPlay 2 can carry 16/44.1 ALAC, 24/48 ALAC or AAC; the sender picks, and what macOS picks is not documented | No | AirPlay 2 can carry 5.1/7.1 as AAC; whether a Mac sends it, or a HomePod plays it as surround, is not documented |
| HomePods via Apple TV 4K | A tvOS app on the Apple TV | Not documented (the Apple TV → HomePod link isn't public) | No | Yes: Atmos, 7.1 and 5.1 on a HomePod pair; four HomePods on the new Apple TV 4K |
| Sonos (S2) | Its local UPnP control on port 1400, playing a URL Vespertine serves | 24-bit / 48 kHz FLAC, lossless | No | No over the network for us; Atmos only from approved music services |
| Sonos (AirPlay 2 models) | AirPlay 2 from the Mac | Same as HomePod above | No | No |
| Sonos Arc / Arc Ultra / Beam | HDMI from the Mac, through a TV's eARC | Multichannel PCM | Up to what the TV and eARC pass | Multichannel PCM, TrueHD and Atmos over eARC |

### Apple

- **AirPlay 2 has no public specification.** What is known comes from Shairport Sync, an open-source receiver ([AIRPLAY2.md](https://github.com/mikebrady/shairport-sync/blob/master/AIRPLAY2.md), describing version 5.6 on).
  - There are two stream types. "Realtime" works like classic AirPlay, about two seconds behind; "buffered" can arrive faster than it plays.
  - The formats it has received are ALAC 16/44.1 realtime; AAC 44.1 and 48 kHz buffered; **ALAC 24-bit / 48 kHz buffered (lossless)**; and **5.1 and 7.1 AAC at 48 kHz buffered (surround, lossy)**.
  - It doesn't play 96 or 192 kHz, or Atmos.
  - It accepts AirPlay 2 from iOS, macOS 10.15 and later, HomePod mini and Apple TV, but doesn't say which sender uses which format.
  - Which format macOS's system AirPlay output sends, and whether an app's own AirPlay playback (AVFoundation) sends something better, is not documented. Test A below finds out.
- **HomePod's documented 24-bit / 48 kHz lossless is Apple Music on the HomePod itself.** A HomePod that streams Apple Music directly can share it with other HomePods at up to 24/48. 2021 coverage puts AirPlay from an iPhone at 16/44.1 ([MacRumors](https://www.macrumors.com/guide/apple-music-lossless/)); Shairport Sync's newer findings above suggest that limit may no longer hold for every sender.
- **Surround on HomePods comes from an Apple TV 4K.** A HomePod stereo pair plays Dolby Atmos, 7.1 and 5.1 from it. The original HomePod mini can't play these formats and plays them in mono or stereo instead ([Apple](https://support.apple.com/en-in/guide/tv/atvb66f63f15/tvos)).
- **The new Apple TV 4K (November 13, 2026) drives four HomePods:** front left/right and rear left/right. HomePod mini 2 and HomePod 2 can be mixed if the front and rear pairs each match. Apple says it detects speaker positions and sets timing and levels itself. Older Apple TV 4K models stay at two ([MacRumors](https://www.macrumors.com/2026/10/13/new-apple-tv-4k-four-homepods-surround-sound/), [9to5Mac on tvOS 27.2](https://9to5mac.com/2026/09/23/tvos-27-2-adds-new-homepod-surround-sound-feature-to-apple-tv-4k/)). Which formats the four-speaker mode plays is not documented.
- **On an Apple TV, Atmos comes from Dolby Digital Plus (E-AC-3) tracks.** TrueHD reaches the output as multichannel PCM ([Infuse staff](https://community.firecore.com/t/true-hd-atmos-as-pcm-stereo-instead-of-multichannel/39931)).
- **HomeView ($299, November 13, 2026)** has "Spatial Audio with Dolby Atmos for music and video" and multiroom AirPlay. Apple's spec page lists no lossless and no audio formats ([Apple](https://www.apple.com/apple-homeview/specs/)).
- **HomeView has no App Store.** Third-party audio apps built for CarPlay run on a paired iPhone or iPad and show up on the HomeView's screen ([MacRumors](https://www.macrumors.com/2026/10/13/homeview-third-party-apps/)). An iOS Vespertine with a CarPlay audio interface would therefore reach it; otherwise it is an AirPlay speaker.
- **HomePods run no third-party apps at all.**

### Sonos

- **Formats:** FLAC up to 48 kHz over HTTP or HTTPS, plus AAC, MP3, Vorbis and WMA. Nothing above 48 kHz ([Sonos developer docs](https://docs.sonos.com/docs/supported-audio-formats)). S2 plays 24-bit FLAC and ALAC at 44.1 and 48 kHz ([Sonos S2 announcement](https://en.community.sonos.com/announcements-228985/introducing-s2-new-app-and-os-for-sonos-6841762)).
- **Control:** Sonos's official Control API is cloud-based and for approved partners. The local UPnP interface on port 1400 is what SoCo, Home Assistant and others use. Sonos doesn't document it, but a 2026 integration page says it still works on Era 100, Era 300 and Arc Ultra, while Sonos slowly moves to a newer local API ([TapHome](https://taphome.com/en/compatibility/sonos/)). It could be removed in a future firmware.
- **Atmos over the network** is offered to approved content partners. Sonos doesn't publish the codec, so it's out of reach for Vespertine.
- **Arc Ultra over HDMI eARC** takes multichannel PCM, Dolby TrueHD and Atmos ([Sonos](https://www.sonos.com/en-us/shop/arc-ultra), [TV requirements](https://support.sonos.com/en-us/article/tv-requirements-for-sonos-home-theater-speakers)).

## Plan

Each step has a test that decides whether the next one is worth building.

1. **Test B: surround from a third-party app on an Apple TV** ([speaker probe](../verification/hardware/speaker-probe/README.md)). This is the go/no-go for step 4 and needs only an Apple TV 4K, ideally with HomePods as its audio output. It plays channel-ID tones in 2.0, 5.1 and 7.1 PCM and records what tvOS reports: channel count, the route and the rendering mode (stereo, surround, Dolby Atmos and so on).
2. **Test A: what a Mac sends over AirPlay** (the same [speaker probe](../verification/hardware/speaker-probe/README.md), Mac target). No HomePod is needed.
   - Run Shairport Sync 5.6 or later in AirPlay 2 mode on a second machine. A Raspberry Pi or another Mac works; its docs list Linux, macOS, FreeBSD and OpenBSD. Use a real machine rather than a VM unless the output is `stdout` or a pipe.
   - Play to it at verbose logging and note the stream type and format it reports, for each of these:
     - (a) Vespertine through the system AirPlay output it uses today;
     - (b) a 24/48 file and a 5.1 file through AVFoundation's own AirPlay playback (`AVPlayer` with an `AVRoutePickerView`);
     - (c) the Music app, for comparison.
   - If (b) gives ALAC 24/48 or 5.1/7.1 where (a) doesn't, Vespertine gains an AirPlay output built on it.
   - Either way, the signal path can then say exactly what an AirPlay speaker gets instead of only "AIRPLAY".
3. **A Sonos lossless sender.**
   - Vespertine serves each track over HTTP as FLAC at 48 kHz or below, from a small server bound to the local network.
   - It finds Sonos players over SSDP and plays the URL through the AVTransport service on port 1400.
   - Rooms are grouped through the same interface.
   - Above-48 kHz PCM is converted down and DSD converted to PCM. Multichannel files are folded to stereo. The signal path names each of these, the same way it does for any other output.
   - Most of it can be tested against any UPnP renderer, for example gmrender-resurrect on Linux, before a real Sonos. Doing so adds generic UPnP renderer output too, which changes the README's "No UPnP/DLNA" line.
4. **A tvOS receiver app, if test B passes.**
   - The Mac serves the library and decoded audio over the local network.
   - The Apple TV app outputs it as multichannel PCM, or passes Atmos (E-AC-3) through to AVFoundation, to whatever the Apple TV's output is: HomePods, a TV or an eARC soundbar.
   - VespertineKit is macOS-only today (`platforms: [.macOS(.v14)]`), and its exclusive (hog) mode and Core Audio HAL control don't exist on tvOS. The decoders, library and analysis would have to be split out to build for tvOS.
   - Distribution would be the App Store or TestFlight; the copyright holder can grant the App Store an exception to the GPL.
5. **An iOS app with a CarPlay audio interface,** which is what HomeView shows. It's lower priority, because HomeView is an AirPlay speaker anyway.

**Not possible on these speakers:**
- Anything above 48 kHz
- Bit-perfect playback
- Atmos to Sonos over the network
- DTS on HomePods other than as decoded PCM
- Lossless surround over AirPlay: the surround formats known so far are AAC

## What the signal path will say

These outputs follow the same rule as every other one. BIT-PERFECT is never shown on them, and every change to the samples (resampling, downmix, lossy encoding by the sender, rendering by the speaker) is named. Where the change happens out of Vespertine's sight, the signal path says what it knows and that the rest is the speaker's.
