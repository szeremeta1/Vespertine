# Addendum to the iPhone plan: multichannel and Spatial Audio on AirPods Max

Date: 2026-11-13. Addendum to `~/Workspace/scratch/2026-11-12-vt-ios-full/PLAN.md` (read that first). Planning and API research only; no iOS audio code has run on a device. Based on `szeremeta1/Vespertine` main at `cad7f47`.

Labels (as in the plan): **[repo]** read in the Vespertine code or docs. **[sdk]** read in the iPhoneOS 27.1 SDK headers on this hub (confirms the API exists and its documented behaviour, not how it sounds). **[known]** Apple platform behaviour I'm confident of. **[unverified]** needs a bench test on a real iPhone and real AirPods Max before we rely on it.

---

## TL;DR (plain English)

- On the Mac, Vespertine already renders 5.1/7.1 itself: it hands the channels to Apple's spatial mixer ("ambience bed", headphones output, personalized HRTF when the listener has one, head tracking on) and gets two binaural channels back for the AirPods [repo `Spatial.swift`]. The iPhone should do the same thing, with Apple's public iOS APIs doing the same job.
- **Two ways to get spatial on AirPods Max on iOS**, and we want both, chosen per track and per setting:
  1. **System path** (iOS does the work): give iOS a multichannel stream with a proper layout, tell the audio session the app can supply multichannel content, and the system's own spatializer renders it for AirPods when the user has Spatial Audio on in Control Center. Head tracking follows the user's Control Center choice. Least code, most "native". We don't control or see the rendering.
  2. **Engine path** (we do the work): `AVAudioEngine` → player node (5.1/7.1 with its layout) → `AVAudioEnvironmentNode` in *ambience bed* mode, output type *headphones*, head tracking on → two channels out. This is the iOS twin of the Mac's code. We control mode (Off / Fixed / Head Tracked), we can show what's happening, and it works for our own queue and gapless. Cost: more code, and a double-processing risk to bench (below).
- **DSD 5.1 and any other multichannel the phone can't decode** reaches the phone as a multichannel FLAC made on the Mac (this job, M2), with the speaker positions sent alongside, so the phone never guesses which channel is which. The phone never decodes DSD.
- **Honest limits:** nothing here can be tested on the hub (no AirPods Max, no iPhone, and the Simulator has no spatial audio or head tracking). Whether the iOS renderer sounds the same as the Mac's, whether head tracking works over the USB-C cable, and whether iOS applies its own spatializer on top of ours are all **[unverified]** and are the first things to bench. Nothing about this path is "bit-perfect", and the app must never say so for a spatial track.

---

## 1. What iOS does natively with a multichannel item, and what we must do

### 1.1 The system path (AVPlayer, or the app's own multichannel output)

| Fact | Label |
|---|---|
| `AVPlayerItem.allowedAudioSpatializationFormats` tells `AVPlayer` which content it may spatialize (mono/stereo/multichannel). For **audio-only** items the default is **multichannel only**: `AVPlayer` "will attempt to spatialize any decodable multichannel layout"; stereo is left alone. | [sdk] `AVPlayerItem.h` |
| So a 5.1 or 7.1 FLAC/ALAC played with `AVPlayer` on AirPods with Spatial Audio on is spatialized by iOS, and a stereo track is untouched (good for the "pure" path). | [sdk] for the default; the audible result [unverified] |
| `AVAudioSession.setSupportsMultichannelContent(true)` (iOS 15+) is how an app that outputs multichannel itself says so; the header says it is "intended to be used by Now Playing applications". `AVAudioSession.maximumOutputNumberOfChannels` / `setPreferredOutputNumberOfChannels(_:)` exist for routes with more channels (USB/HDMI). | [sdk] `AVAudioSession.h` |
| `AVAudioSessionPortDescription.isSpatialAudioEnabled` (iOS 15+) says whether the current route can play spatialized audio; `AVAudioSession.spatialPlaybackCapabilitiesChangedNotification` fires when that changes (observe the route-change notification too). | [sdk] `AVAudioSessionRoute.h`, `AVAudioSessionTypes.h` |
| `AVAudioSession.renderingMode` (iOS 17.2+, read-only) is the resolved mode (`.monoStereo`, `.surround`, `.spatialAudio`, `.dolbyAudio`, `.dolbyAtmos`, `.notApplicable`), "to badge content appropriately"; `renderingModeChangeNotification` reports changes. | [sdk] `AVAudioSession.h`, `AVAudioSessionTypes.h` |
| **There is no iOS API to force the system spatializer or head tracking from an app.** `setIntendedSpatialExperience` (head tracked / fixed / bypassed) exists only for visionOS in this SDK. On iOS the user's Control Center setting (Off / Fixed / Head Tracked) decides. | [sdk] `AVAudioSession.h` (`#if TARGET_OS_VISION`) |
| Whether the system spatializer also processes an app's **own `AVAudioEngine` output** (as opposed to `AVPlayer` or a multichannel session) the same way. | [unverified] |

**Consequences.** On the system path we must: (a) deliver a decodable multichannel stream with a **correct channel layout** (a wrong or missing layout is the usual reason iOS treats it as plain stereo or discrete channels [known]); (b) set the session up (`.playback`, `setSupportsMultichannelContent(true)`); (c) read back `isSpatialAudioEnabled` and `renderingMode` and show them; (d) accept that head tracking is the user's system choice and we only display it. We do *not* get Off/Fixed/Head-Tracked control inside the app on this path, and we can't offer "Fixed" if the user's system choice is "Head Tracked".

### 1.2 The engine path (what Vespertine does on the Mac, done with AVAudioEngine)

The pieces, all in the iOS SDK:

- `AVAudioEnvironmentNode` with `outputType` (`.auto`, `.headphones`, `.builtInSpeakers`, `.externalSpeakers`, iOS 13+). The header says wired output isn't auto-detected, so set it to `.headphones` and keep it in step with route changes. [sdk]
- Per-input `AVAudio3DMixingSourceMode.ambienceBed` (iOS 13+): "the input channels are spatialized around the listener as far-field sources... The directions of the input channels are specified by the AudioChannelLayout of the bus." By default **only mono inputs are spatialized**, so setting the source mode to `.ambienceBed` on the player node is required. [sdk] `AVAudioMixing.h`, `AVAudioEnvironmentNode.h`
- Rendering algorithm per source: `.HRTFHQ` or `.auto` (with output type headphones, `.auto` follows the output type). [sdk] The Mac uses the equivalent "use output type" algorithm. [repo]
- `AVAudioEnvironmentNode.isListenerHeadTrackingEnabled` (iOS 18+): "listener orientation will be automatically rotated based on user's head-orientation if enabled" on capable devices. [sdk] Below iOS 18, head tracking needs `CMHeadphoneMotionManager` (iOS 14+; AirPods with motion sensors) feeding `listenerAngularOrientation` ourselves, which needs the Motion & Fitness permission string. [sdk, known]
- The underlying audio unit, `kAudioUnitSubType_SpatialMixer`, and its properties (`...SpatialMixerOutputType`, `...EnableHeadTracking`, `...PersonalizedHRTFMode`, `...AnyInputIsUsingPersonalizedHRTF`) are declared in the iOS SDK's AudioToolbox headers. The header describes head tracking as "using AirPods motion sensors". [sdk] That is the unit the Mac's `SpatialRenderer` drives directly. [repo] Using it directly on iOS (through an `AVAudioUnit` wrapper or a render callback) is possible but not needed unless the environment node can't do something we need (personalized HRTF readback is the likely one). [unverified]

**What we must do on this path:**

1. Build the layout from **labels the Mac sent**, never from the file: `AVAudioChannelLayout` from `AudioChannelDescription`s (the Mac's `ChannelLayouts.layout(labels:)` does this) [repo]. Core Audio's FLAC reader may or may not report a layout from the file's channel mask [unverified]; the Mac's own precedent is that unlabeled channels fell back to the first two for large sets ("with no names, Apple's spatial mixer heard only the first two") [repo].
2. Route each source channel to the bed speaker of its own place before the mixer (the Mac's `BedRouter` and `ChannelLayouts.spatialBed(for:)`), because Apple's converter turned whole streams silent on beds with speakers it couldn't feed. That was found on macOS with heights and 16-channel sets [repo]; 5.1 and 7.1 are the standard cases but should be re-checked on iOS. [unverified]
3. Set `outputType = .headphones`, source mode `.ambienceBed`, and head tracking per the user's mode (Off: bypass the environment node and send a plain downmix; Fixed: no head tracking; Head Tracked: `isListenerHeadTrackingEnabled = true` on iOS 18+, `CMHeadphoneMotionManager` below).
4. Run the engine at the session's rate (48 kHz or 44.1 kHz on a Bluetooth link and on AirPods Max's cable [repo `DeviceProfile`]) and let the stream arrive already at that rate (section 3). Do not ask iOS for a rate on a Bluetooth route: the Mac learned the hard way that a Bluetooth link refuses other rates while any app has the mic open [repo `BluetoothOutput.swift`]. On iOS: read `session.sampleRate`, convert to it, show it.
5. Never put the spatial path under the "bit-perfect" badge. Show "Spatial Audio · head tracked / fixed", the real session rate, and `renderingMode`, like the Mac's signal path does. [repo `SignalPath`]

### 1.3 The double-processing risk (first bench item)

If the engine path outputs two binaural channels and iOS (Spatial Audio on) *also* treats that stereo as content to spatialize, the listener gets a spatialized spatialization: too wide, wrong EQ, head tracking applied twice. The Mac's equivalent is "two channels out" to the AirPods device [repo `stereo-spatialize.md`]; whether macOS re-spatializes that pair is not recorded in the repo, and **iOS's behaviour for an engine that outputs stereo with Spatial Audio on is [unverified]** too. Bench: play a known 5.1 test file by (1) `AVPlayer` system path, (2) engine path, (3) a stereo binaural render of the same file, with the system toggle on Off / Fixed / Head Tracked, and listen for doubling. If doubling is real, the engine path may have to hand the system a *multichannel* signal after all (so the system is the only spatializer), which collapses the engine path into the system path. That's a fine outcome: it is the simpler design.

### 1.4 Head tracking: what to expect

- System path: the user's Control Center mode. We display it (`renderingMode`, `isSpatialAudioEnabled`). [sdk, known]
- Engine path: iOS 18+ property, or CoreMotion below. Both need AirPods with motion sensors (AirPods Max has them [known]). Whether it keeps working with the screen locked and the app in the background is **[unverified]** (CoreMotion headphone updates may be suspended in the background); music apps live in the background, so this must be benched before we offer "Head Tracked" as an in-app mode.
- Over the **USB-C cable** the AirPods Max play lossless 24-bit/48 kHz on the Mac [repo `DeviceProfile`: `airPodsMaxUSB`]. Whether iPhone head tracking and Spatial Audio work while cabled is **[unverified]**.

---

## 2. Source types and how each reaches the AirPods

| Source | What the Mac sends | What the phone does |
|---|---|---|
| Stereo FLAC/ALAC/WAV | The original bytes. | Plays untouched (system path leaves stereo alone), or, with a "Spatialize stereo" switch like the Mac's, the upmix (below). |
| **5.1 / 7.1 FLAC, ALAC, WAV** (≤ 8 channels) | The original bytes, plus the **speaker labels** and the `channels`/rate in the stream descriptor (M2). | System path: `AVPlayer` item, or engine path with the layout built from the labels. |
| **DSD 5.1** (DSF/DFF multichannel, SACD-ISO area) | The **Mac decodes DSD→PCM** (its decoder already reads the channel labels from DSDIFF/DSF) and sends a **multichannel FLAC** (M2 `StreamPreparer`), 24-bit, at the rate the phone said it can use (the whole point of `maxSampleRate`), labels attached. | Same as 5.1 PCM. The phone never sees DSD. |
| DTS, TrueHD (MLP), DVD-LPCM, APE/WavPack/TTA multichannel | Same: the Mac decodes (it already can [repo `DTSDecoder`, `DVDVideoDecoder`, FFmpeg subset]) and sends multichannel FLAC. | Same. |
| **More than 8 channels** (5.1.4, 7.1.4, 16-ch), Dolby Atmos objects | FLAC stops at 8 channels [repo: SFBAudioEngine's FLAC encoder accepts 1–8]. **Not streamable as multichannel in M2.** | Offer instead the Mac-rendered binaural stereo (next row), or "plays on the Mac only". Honest limit. |
| **Any multichannel, for headphones that aren't AirPods** (or AirPods with Spatial Audio off) | Optional: the Mac renders **binaural stereo** with its own spatial renderer (`MultichannelExport.spatialStereo` is exactly this, offline, fixed, no head tracking [repo]) and streams stereo FLAC. | Plays as stereo. Works on any headphones, costs no phone CPU, no head tracking. A fallback, not the default. |

Rules (same as the Mac's): the phone treats the speaker labels as the truth; an unlabeled multichannel file gets the standard order for its count (`ChannelLayouts.standardTag`) [repo]; FLAC's own channel order for 6 and 8 channels is the WAVE order (FL FR FC LFE BL BR SL SR for 7.1, which differs from Core Audio's MPEG 7.1 order) [repo `wavOrderLabels`, `SFBFLACEncoder`], so, **as built in M2**, the Mac keeps the decoder's own channel order in the FLAC it writes and sends that order's speaker labels (`StreamFormat.channelLabels`, Core Audio `AudioChannelLabel` values); the phone builds its layout from those. For 5.1 every convention agrees. For 6.1 and 7.1 the file's own implied order (FLAC's WAVE order) can differ from the labels, which matters only to the `AVPlayer` system path (it reads the file's layout, not ours): writing the FLAC in WAVE order for those counts is a follow-up before the system path is offered for 6.1/7.1 [unverified that Core Audio's FLAC reader reports a layout at all].

### Stereo "Spatialize stereo" on the phone

The Mac's upmixer (`StereoUpmix.swift`: STFT primary/ambient, 5.1 out, ≈7 FFTs per hop, compensated latency) is plain vDSP and decode-thread work [repo `docs/plans/stereo-spatialize.md`]. Two ways to reuse it, later (M3+):

- **On the phone** (port the file to a shared package; no extra bandwidth, works with any stereo track). Preferred. CPU on a phone is small at 48 kHz [unverified on device].
- **On the Mac** (a `spatializeStereo` flag on the stream request, 5.1 FLAC out). Costs 3× the bandwidth. Only if the phone port is slower than expected.

The sound parameters in that doc still need the listening session it asks for; the phone inherits them.

---

## 3. Bandwidth and rate: render at the route's rate

Multichannel at DSD-converted rates is large: 5.1 at 24-bit/176.4 kHz is 25 Mbit/s as raw PCM, about 13–17 Mbit/s as FLAC [estimate, matches the plan's "30+ Mbit/s" worst case]. AirPods render at 44.1/48 kHz anyway [repo, known]. So the stream request carries **`maxSampleRate`**: the phone says what its route can use (48 000 for an AirPods route; the DAC's top rate for a USB DAC), and the Mac's `StreamPreparer` converts down while transcoding (and refuses to *up*convert). That cuts a DSD 5.1 stream to about 3–4 Mbit/s as FLAC for AirPods, and makes Tailscale and cellular realistic. Original files that are already within `maxSampleRate` are sent as they are (no transcode); a file above it (a 24/192 FLAC for an AirPods route) can be sent as an original (the phone resamples) or transcoded to the lower rate (saves bandwidth): the descriptor says which, and the user setting chooses.

---

## 4. Reuse map: Mac code to iOS

| Mac code [repo] | Reuse on iOS | How |
|---|---|---|
| `SpatialMode` (off/fixed/headTracked) | Yes | Move to a shared, iOS-capable package. |
| `ChannelLayouts` (`standardTag`, `layout(labels:)`, `wavOrderLabels`, `spatialBed`, names) | Yes, essential | Pure AVFAudio/Core Audio types. Needs extracting from `VespertineAudio`, which is macOS-only because of the HAL/IOKit code around it. |
| `BedRouter` (channel → bed speaker) | Yes, essential | Same extraction. |
| `SpatialRenderer` (AUSpatialMixer + `CVespertineRT` bridge, I/O-thread slices) | Not as it is | The bridge exists to run the mixer on the macOS I/O thread; on iOS `AVAudioEngine` pulls. Keep the AU settings (ambience bed, use-output-type, headphones, personalized HRTF auto, head tracking) as the reference for the environment node. |
| `StereoUpmixer` + planner rules (`canSpatializeStereo`) | Yes, later | vDSP only. |
| `BluetoothOutput` rules (never hold/switch a Bluetooth link; follow its rate; call-mode note) | The lesson, not the code | iOS: read `session.sampleRate`, convert to it, show call-mode. |
| `SignalPath` wording ("Spatial Audio · head tracked", never "bit-perfect") | Yes | Phone's signal-path model uses the same strings. |
| `MultichannelExport.spatialStereo` | Yes, on the Mac side | The "binaural stereo for any headphones" fallback in section 2. |
| `SourceOpener` + decoders (DSD→PCM, DTS, TrueHD…) | Mac side only | M2 `StreamPreparer` calls it. |

---

## 5. Bench checklist (hardware; Alex's iPhone + AirPods Max, USB-C cable if he has it)

Each line is a yes/no/notes entry for `docs/IOS-AUDIO-BENCH.md` (M0 in the plan).

1. 5.1 FLAC through `AVPlayer`, AirPods Max on Bluetooth, Control Center Spatial Audio Off / Fixed / Head Tracked: audible difference? `renderingMode` and `isSpatialAudioEnabled` values.
2. Same file through the engine path (`AVAudioEnvironmentNode`, ambience bed, headphones): does it sound like (1)? Doubling check (section 1.3).
3. Head tracking on the engine path: iOS 18 property vs CoreMotion; does it keep working with the screen locked?
4. 7.1 FLAC (WAVE order): are the rears and sides in the right places? (Channel-order test file: one tone per channel, announced by name.)
5. Personalized HRTF in use? (`kAudioUnitProperty_SpatialMixerAnyInputIsUsingPersonalizedHRTF` via the AU, or by ear.)
6. Mac vs iPhone A/B with the same 5.1 file on the same AirPods: same sound?
7. USB-C cable to AirPods Max: do Spatial Audio and head tracking work? Session rate and depth read-back.
8. Bluetooth call mode: start a call-app mic, confirm the app shows call mode and doesn't loop trying to change rate (the 1.1.1 Mac bug [repo]).
9. Stream: DSD 5.1 → FLAC at 48 kHz over Wi-Fi and over Tailscale: buffer health, CPU, battery over 30 minutes.
10. Lock screen, route change (unplug/disconnect), interruption (call) while a spatial 5.1 track plays.

---

## 6. Honest limits (summary)

- No hub-side audible test is possible: no AirPods Max or iPhone on this machine, and the Simulator has no spatial audio or head tracking. Everything in sections 1.1–1.4 marked [unverified] stays unverified until the bench.
- We can't force the system's spatializer or head tracking from an iOS app (the intended-experience API is visionOS-only in the 27.1 SDK). On the system path the user's Control Center choice rules.
- Spatial output is never bit-perfect, on any device; over Bluetooth it also goes through AAC. Lossless-to-the-ear claims are for the cabled AirPods Max only, and only after measurement.
- Up to 8 channels. Heights/Atmos objects and 9+ channel sets aren't streamed as multichannel.
- Whether iOS's environment node renders identically to the Mac's AUSpatialMixer, and whether personalized HRTF is applied on the engine path, are untested.
- Sound parameters for Spatialize stereo (ambience level, centre strength, LFE) still need the listening session the Mac doc asks for.
