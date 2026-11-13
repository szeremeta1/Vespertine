# AirPlay output (1.0 / RAOP and 2.0): research spike

Date: 2026-11-13. Status: research only, no product code. Question from the owner: *can the UPnP/OpenHome renderer
infrastructure (spec `docs/superpowers/specs/2026-11-13-upnp-output-design.md`, branch `upnp-output`, being built in the
`Vespertine-trackC` tree) also offer AirPlay 1 and 2 streaming "in the best possible way for the current file"?*

Evidence labels used on every claim:

- **[V]** verified from source: read in the code of the named project (shallow clones of the upstream default branches
  on 2026-11-13: shairport-sync 5.6.3 `7ce90d8`, OwnTone `8ed84f2` (2026-11-10), pyatv 0.18.0 `b277a4c`, libraop
  `c14088d` (2026-10-28), AirConnect `e2758fd`, libairptp, and the macOS SDK headers in the installed Xcode).
- **[D]** documented: stated in a project's or Apple's documentation, or reported by a named vendor.
- **[I]** inferred: my reasoning from the above, or a community report that I could not confirm. Treat as a hypothesis to test.

Links to source files point at the upstream GitHub repositories. Line numbers refer to the commits above.

---

## 0. Short answer

- **Hi-res over AirPlay doesn't exist for us.** Nothing above 48 kHz goes over AirPlay to any receiver we can reach.
  shairport-sync says so outright: "High-Definition Lossless -- 96,000 and 192,000 fps material -- is not supported"
  ([AIRPLAY2.md](https://github.com/mikebrady/shairport-sync/blob/master/AIRPLAY2.md)) **[D]**. Its AirPlay 2 receiver
  recognises only six stream formats. The best of them is **ALAC 24-bit / 48 kHz stereo, buffered** (`player.h`
  `ssrc_t`) **[V]**.
- **What a third-party sender can realistically send:**
  - **RAOP (AirPlay 1):** ALAC 16/44.1 stereo. This can be sent **bit-perfect** for CD-format sources **[V]**.
  - **AirPlay 2 "realtime" (type 96):** also ALAC 16/44.1 only, to shairport-sync **[V]**. It adds pairing, PTP timing and
    multi-room, but no extra quality.
  - **AirPlay 2 "buffered" (type 103):** the only route to 24/48 lossless. No open-source *sender* that implements it
    was found **[I]**. We would be first, working from the receiver's code.
- **FairPlay isn't needed** for audio to shairport-sync, and the open-source senders don't implement it
  (OwnTone never sends `/fp-setup`) **[V]**. AirPlay 2 needs HomeKit pairing (transient, or PIN for some Apple TVs),
  ChaCha20-Poly1305 encryption and PTP timing. All of it is documented by open-source code.
- **A built-in limit on bit-perfection:** with AirPlay, *the sender's clock is the master*. The receiver adds or removes
  frames to stay in sync unless synchronisation is turned off on it (shairport-sync `interpolation`,
  `disable_synchronization`) **[D]**. So even a stream that leaves the Mac bit-perfect is not promised bit-perfect at the
  DAC, and that is worse than UPnP, where the renderer pulls the file on its own clock. Badges must say **"SENT"**, as
  in the UPnP design.

Recommendation, in short (details in §6):

- **Phase 1:** RAOP, ALAC 16/44.1. It is bit-perfect *as sent* for 16/44.1 sources; other sources get mastering-quality
  SRC and TPDF dither to 16 bits. It also works on most third-party speakers.
- **Phase 2:** AirPlay 2 buffered ALAC 24/48 to shairport-sync, as an experimental, receiver-driven feature.
- **HomePod / Apple TV:** best effort, and not before Phase 2 is stable. Apple broke third-party AirPlay 1 audio to
  HomePods with OS 27 in September 2026 (details in §1.6).

---

## 1. AirPlay 1 (RAOP) as a sender

### 1.1 Session shape

- RTSP over TCP: `OPTIONS` → `ANNOUNCE` (SDP) → `SETUP` → `RECORD` → `SET_PARAMETER` (volume, progress, DMAP metadata,
  artwork) → `FLUSH` / `TEARDOWN`. Audio goes as RTP over UDP (payload type 96, 352 frames per packet). The other two
  ports are a control port (sync packets, retransmit requests) and a timing port (NTP-like request/response).
  Sources: pyatv
  [protocols.md › RAOP](https://github.com/postlund/pyatv/blob/master/docs/documentation/protocols.md),
  libraop [`raop_client.c`](https://github.com/philippe44/libraop/blob/master/src/raop_client.c),
  OwnTone [`raop.c`](https://github.com/owntone/owntone-server/blob/master/src/outputs/raop.c) **[V]**.
- Discovery: mDNS `_raop._tcp`. TXT keys include:
  - `cn`: codecs, 0 = PCM, 1 = ALAC, 2 = AAC, 3 = AAC-ELD
  - `et`: encryption, 0 = none, 1 = RSA (AirPort Express), 3 = FairPlay, 4 = MFiSAP, 5 = FairPlay SAPv2.5
  - `sr`, `ss`, `ch`: sample rate, sample size, channels
  - `pw`: password; `sv`: software volume
  
  Source: pyatv protocols.md table **[D]**.

### 1.2 Audio formats

- **The SDP format line.** The `a=fmtp:96` line carries the ALAC configuration:
  `frames/packet, 0, sample size, 40, 10, 14, channels, 255, 0, 0, sample rate` (pyatv protocols.md) **[D]**.
- **What senders send.** Every open-source sender sends 16/44100/2:
  - OwnTone hard-codes `a=fmtp:96 %d 0 16 40 10 14 2 255 0 0 44100` (`raop.c` l.1189) **[V]**.
  - libraop fills sample size and rate from its parameters (`raop_client.c` l.855) **[V]**, but AirConnect and cliraop
    feed it 44100/16.
- **What shairport-sync accepts.**
  - **Classic-only builds:** the ANNOUNCE handler parses *any* fmtp sample size and rate into `input_bit_depth` and
    `input_rate` (`rtsp.c` l.3624–3658) **[V]**.
  - **FFmpeg builds:** these are required for AirPlay 2, so moOde's build is one of them **[I]**. In these builds every
    classic RTP packet is tagged `ALAC_44100_S16_2` (`rtp.c` l.281). `setup_software_resampler` then forces
    `input_rate = 44100`, `input_bit_depth = 16` for that tag (`player.c` l.551–566) **[V]**.
  - **So:** a 24-bit or 48 kHz fmtp would be mis-decoded. The project's own docs say "Classic AirPlay offers only one
    format, ALAC/S16/44100/2" (AIRPLAY2.md) **[D]**.
  - **Answer to "is anything other than 44100/16 stereo accepted?":** not in practice. Real receivers, Apple's included,
    advertise and expect 44100/16/2 **[I]**, and no sender sends anything else.
- **Uncompressed PCM.** `a=rtpmap:96 L16/44100/2` is also accepted by shairport-sync (`rtsp.c` l.3516–3549), still
  fixed at 44.1/16 **[V]**. pyatv sends this form.
- **Lossless "verbatim" ALAC.** ALAC frames can carry uncompressed samples. OwnTone has `alac_encode_uncompressed`
  (`raop.c` l.411) behind the option "uncompressed ALAC" **[V]**. So the sender needs **no real ALAC encoder**:
  verbatim frames are lossless by construction. They cost about 1.4 Mbit/s, which is fine on a LAN. Compressed ALAC
  via Apple's AudioConverter (`kAudioFormatAppleLossless`; `afconvert -hf` lists `alac` encode) is optional. OwnTone
  switched to compressed ALAC "for bandwidth + fixes esp32 issue" (ChangeLog) **[D]**.
- **AAC.** Possible in RAOP (`cn=2`), but lossy, so pointless here.

### 1.3 Encryption

- AES-128-CBC over each packet's whole 16-byte blocks, with the trailing partial block sent in the clear. The AES key
  is wrapped with RSA-OAEP using the well-known AirPort Express *public* key. It is embedded in OwnTone (`raop.c`
  l.276 `raop_rsa_pubkey`) and libraop (`rsa_encrypt`, `RSA_PKCS1_OAEP_PADDING`) **[V]**. A sender needs only that
  public key, never a private key.
- Encryption is **optional** for receivers that allow it:
  - shairport-sync takes an ANNOUNCE without `rsaaeskey`/`aesiv` as an unencrypted session (`rtsp.c` l.3588) **[V]**.
  - OwnTone omits the keys when not needed ("important for ATV3 update 6.0", `raop.c` l.1214) **[V]**.
  - libraop notes "with newer airport express, don't use encryption (??)" **[V]**.
  
  Implement both. AES-CBC and RSA-OAEP are available in CommonCrypto and Security.framework.
- Apple TV 4 and later need "device verification" (legacy pair-setup with a PIN) even for RAOP. pyatv: "only used to
  verify a connection, it does not enforce any encryption" (supported_features.md) **[D]**.

### 1.4 Timing and sync

- RTP timestamps count frames at 44100/s. The sender sends sync packets on the control port, mapping RTP time to NTP
  time (latency is usually around 2 s), and answers the receiver's timing requests. libraop's comments document the
  TS↔NTP arithmetic (`raop_client.c` l.58–66) **[V]**.
- **The sender's clock rules.** The receiver tracks it and corrects drift by inserting or removing frames
  (shairport-sync `interpolation`: `soxr` / `vernier` / `basic`). The default `drift_tolerance_in_seconds = 0.002`
  (scripts/shairport-sync.conf) **[D]**. To get untouched samples to the DAC, the receiver needs
  `disable_synchronization = "yes"` (an ALSA backend option) or the `pipe`/`stdout` backends ("No interpolation is
  done") **[D]**.
- **Gapless.** One RTP stream can run across tracks of the same format: Vespertine keeps feeding frames, so gapless is
  natural **[I]**. Changing format needs FLUSH/re-SETUP. This doesn't arise in RAOP, which only ever carries 44.1/16.

### 1.5 Volume

- Volume is `SET_PARAMETER volume: <dB>`, from −30 to 0, with −144 for mute (OwnTone and libraop) **[V]**. It is
  metadata: **the samples we send stay untouched** **[V]**.
- The receiver then applies it:
  - shairport-sync attenuates in software unless `mixer_control_name` names a hardware mixer, or
    `ignore_volume_control = "yes"` is set (shairport-sync.conf, alsa section) **[D]**.
  - With software attenuation, the DAC no longer gets the original samples **[I]**.
  - The same lock-at-100% UX as the UPnP design applies.

### 1.6 Who still accepts RAOP

- **shairport-sync:**
  - Classic builds accept RAOP.
  - AirPlay 2 builds still publish `_raop._tcp` ("AirPlay 1 and AirPlay 2", `mdns/mdns_dns_sd.c` l.35) **[V]**, and
    the ANNOUNCE path is the same code **[V]**.
  - `service_type = "auto"` gives AirPlay 2 when NQPTP is present, otherwise classic with "(Classic)" in the name
    (shairport-sync.conf) **[D]**.
- **AirPort Express, older Apple TVs, most third-party AirPlay speakers and AVRs:** these accept RAOP **[D]**. pyatv
  checked streaming on Apple TV 3, Apple TV 4K gen 1 (14.5), HomePod mini (14.5), AirPort Express (7.8.1) and Yamaha
  RX-V773 (supported_features.md).
- **HomePod / Apple TV on OS 27 (September 2026):**
  - Roon staff found that "every AirPlay 2 session setup is refused by the speaker", so Roon falls back to AirPlay 1.
    There "everything reports success" but there is no sound.
  - Rogue Amoeba reportedly saw "the same finding for AirPlay 1 on tvOS 27 and HomePodOS 27" and filed FB24452968
    ([Roon thread](https://community.roonlabs.com/t/ios-27-apple-homepods-fail-to-stream-sound-from-roon-airplay-ref-9ki1fy-hotfix-released/324917)).
  - Roon shipped a hotfix whose content is undisclosed. TidBITS mentions Airfoil 5.13 restoring Apple TV and HomePod
    support. I couldn't open either source.
  - **[D] for the reports, [I] for what changed.**
  - **Conclusion:** RAOP to Apple's own receivers is no longer something to count on.

---

## 2. AirPlay 2 as a sender

### 2.1 What an unofficial sender must implement

1. **Discovery:** `_airplay._tcp` (features bitmask, `pk`, `pi`, `gid`, `flags`). Then `GET /info` (binary plist:
   `statusFlags`, `supportedFormats`, …) **[V]** (shairport-sync `rtsp.c` l.1190–1250; OwnTone `airplay.c`).
2. **Pairing:** HomeKit pair-setup / pair-verify (TLV8, SRP-6a, Ed25519, X25519, HKDF-SHA512, ChaCha20-Poly1305).
   - **Transient pairing** (pair-setup in two steps, no PIN) is the normal case for shairport-sync and most speakers.
     shairport-sync: "Transient pairing completed (pair-setup step 2), prepare encryption" (`rtsp.c` l.1864) **[V]**.
   - **PIN pairing** (`/pair-pin-start`, then a full pair-setup and a stored key) is used when `statusFlags` asks for it
     (OwnTone `airplay.c` l.3826–3855) **[V]**.
   - Some Apple TVs answer transient with 470 and want a PIN: "Some devices (i.e. my ATV4) gives a 470 when trying
     transient" (l.4219) **[V]**.
   - **Password** auth is also supported **[V]**.
   - The reference implementation is **pair_ap** by Espen Jürgensen (MIT), embedded in OwnTone (`src/pair_ap`) and in
     shairport-sync (`pair_ap/`, MIT per `LICENSES`) **[V]**.
3. **After pairing, the RTSP control channel is encrypted** (ChaCha20-Poly1305, 2-byte length + ≤1024-byte block + tag).
   The event channel and, for buffered streams, the data channel are encrypted too. Keys come from HKDF with
   per-channel salt and info strings (pyatv protocols.md › AirPlay 2 › Encryption) **[D]**.
4. **SETUP in two phases**, both with binary plists:
   - Session-level: `timingProtocol`, `timingPeerInfo`, `groupUUID`, … (OwnTone l.3224/3272) **[V]**.
   - Stream-level: `type`, `ct`, `audioFormat`, `spf`, `sr`, `shk` (32-byte stream key), `latencyMin/Max`,
     `controlPort` **[V]** (OwnTone `payload_make_setup_stream` l.3136).
   - macOS writes binary plists natively (`PropertyListSerialization` `.binary`).
5. **Audio packets:** RTP with each payload sealed with ChaCha20-Poly1305 under `shk`. pyatv's
   `Chacha20Cipher8byteNonce(shared_secret, …)` shows the layout **[V]**. AES isn't used in AirPlay 2.
6. **Timing: PTP.**
   - **shairport-sync refuses AirPlay 2 NTP streams.** It logs "ntp stream handling is not implemented!" and "Shairport
     Sync can not handle NTP streams." (`rtsp.c` l.2657–2660) **[V]**.
   - OwnTone 29.1 (2026-04-15) added "shairport-sync Airplay 2 mode via support for PTP timing" and Samsung/Sonos Era
     support the same way (ChangeLog) **[D]**.
   - The sender must be the **PTP master** on UDP 319/320. OwnTone uses **libairptp** (MIT), or the shared daemon
     `airptpd` when the ports can't be bound. Its README says it "is designed to always become master clock, which a
     sender like OwnTone needs" **[D]**.
   - On macOS there is a risk of conflict with the system's own AirPlay stack while the Mac itself is AirPlaying. When
     I checked, nothing was bound to UDP 319/320 on this Mac **[I]**.
7. **Feedback and keep-alive:** `POST /feedback` every few seconds **[V]** (OwnTone `AIRPLAY_SEQ_FEEDBACK`; pyatv
   `_feedback_task`). HomePod and Apple TV 4 drop idle sessions unless progress metadata is sent about every 25 s
   (`AIRPLAY_KEEP_ALIVE_INTERVAL`, OwnTone issue #734) **[V]**.
8. **Optional extras:** MediaRemote now-playing over `/command` (OwnTone, 2026-11-10 commit) and remote-command relay
   on the event channel **[V]**.

### 2.2 FairPlay

- **Not needed for audio to third-party receivers, nor (until OS 27) for HomePod via transient pairing.**
  - OwnTone's AirPlay 2 sender has no fp-setup at all. `grep fp-setup src/outputs/*.c` finds nothing; FairPlay appears
    only as a feature-bit name, "Authentication_4", at l.437 **[V]**.
  - OwnTone classifies HomePods (`AIRPLAY_DEV_HOMEPOD`) and streams to them **[V]**.
- shairport-sync *answers* `/fp-setup` with canned replies (`rtsp.c` l.1896ff) because Apple senders send it. A
  sender doesn't have to **[V]**.
- FairPlay *would* be involved in protected-content and video paths (AirPlay video, FairPlay Streaming). Vespertine
  doesn't need those **[I]**.
- **Legal note:** staying away from FairPlay keeps us clear of anything that could be read as circumventing a copy
  protection measure (see §6.4).

### 2.3 Stream types and formats

AirPlay 2 has two stream types:

| | Realtime | Buffered |
|---|---|---|
| Type | 96 | 103 |
| Transport | RTP over UDP | TCP |
| Delay | about 2 s | short; audio can arrive faster than real time and is buffered on the receiver |

Source: [AIRPLAY2.md](https://github.com/mikebrady/shairport-sync/blob/master/AIRPLAY2.md) **[D]**.

The `audioFormat` bitmask is listed in OwnTone `airplay.c` l.3093–3132 **[V]**. Examples: bit 18 `0x40000`
ALAC/44100/16/2, bit 19 ALAC/44100/24/2, bit 21 `0x200000` ALAC/48000/24/2, bits 22–23 AAC-LC 44.1/48.

**What shairport-sync 5.6 advertises and decodes** (`rtsp.c` l.1215–1245, `player.h` l.152–160, `player.c`
`ssrc_is_recognised`):

| | Realtime (96) | Buffered (103) |
|---|---|---|
| Advertised | `audioStream = 262144` → ALAC/S16/44100/2 only ("just ALAC/S16/2") **[V]** | AAC-LC 44.1/2 and ALAC/44100/S16/2 always; ALAC/48K/24/2 if `lossless_mode` (default on, `shairport.c` l.2758) and not `airplay_2_44100_only_mode`; AAC-LC 48/2; AAC 48 5.1 and 7.1 if enabled **[V]** |
| Format of each packet | — | identified by the RTP **SSRC**: `0x15000000` ALAC_48000_S24_2, `0x16000000` AAC_44100_F24_2, `0x17000000` AAC_48000_F24_2, `0x27000000` AAC 5.1, `0x28000000` AAC 7.1. ALAC_44100_S16_2 is `0x0000FACE`, commented "this is made up" **[V]** |

What this means:

- **24/48 ALAC to a shairport-sync AirPlay 2 receiver is possible**, only as a *buffered* stream with SSRC `0x15000000`
  **[V]**. shairport-sync then suggests S24 output (`player.c` l.568–571) **[V]**.
- **24/44.1 can't be sent losslessly to shairport-sync.** No ALAC 44.1/24 SSRC exists and it isn't advertised **[V]**.
  A 24/44.1 source must become 16/44.1 (dither) or 24/48 (SRC).
- **Buffered ALAC 16/44.1:** advertised, but the SSRC an Apple sender would use is unknown (the "made up" value). A
  sender would have to send `0x0000FACE` **[I]** and test.
- **Nothing above 48 kHz anywhere.**
  - shairport-sync: none **[V]/[D]**.
  - Apple: HomePods do lossless "up to 24-bit/48 kHz". Hi-Res Lossless needs an Apple TV 4K over HDMI to an AVR
    ([Apple support 118295](https://support.apple.com/en-us/118295)) **[D]**. That is HDMI out of the Apple TV, not
    AirPlay into it.
  - WWDC23 "Tune up your AirPlay audio experience" calls enhanced buffering an "intelligent use of Lossless playback
    for iOS" ([session 10238](https://developer.apple.com/videos/play/wwdc2023/10238/)) **[D]**. It names no format and
    doesn't mention macOS.
- **Multichannel to shairport-sync is AAC only** (5.1/7.1, lossy) **[V]**.
- **What Apple senders actually send** (what the owner saw): ALAC/S16/44100 realtime, or AAC buffered, with 24/48 ALAC
  only in "Lossless" cases (AIRPLAY2.md "What Works" list) **[D]**.

### 2.4 Multi-room

- Every receiver in a group follows the sender's PTP clock and the same RTP timeline (`groupUUID`; shairport-sync docs:
  "Audio synchronised with other AirPlay 2 devices") **[D]**.
- A sender that is PTP master can drive several sessions with one master session. OwnTone does this:
  `master_session_make`, shared encoder **[V]**.
- Vespertine could offer grouped AirPlay 2 zones later. That is out of scope for a first phase.

### 2.5 Open-source senders

| Project | Language, license | AirPlay 1 | AirPlay 2 | Formats sent | Notes |
|---|---|---|---|---|---|
| [OwnTone](https://github.com/owntone/owntone-server) | C, GPL-2.0-or-later (compatible with GPL-3 when used under v3) **[V]** | yes, with RSA/AES optional | yes (default since 29.1): transient, PIN, password; PTP via libairptp; MediaRemote | ALAC 16/44.1 realtime type 96 only. "Only default audio quality supported so far" (`airplay.c` l.4613) **[V]** | The most complete; maintained (commit 2026-11-10) |
| [pyatv](https://github.com/postlund/pyatv) | Python, MIT | yes (legacy pairing) | partial: setup type 96, `ct=1` raw PCM 44.1/16 **[V]**; "encryption has not been implemented for HAP based authentication" in RAOP **[D]** | PCM 16/44.1 | Good protocol documentation |
| [libraop](https://github.com/philippe44/libraop) / [AirConnect](https://github.com/philippe44/AirConnect) | C, MIT **[V]** | yes, with NTP-synchronised multi-player | no (Apple TV pairing only) | ALAC/PCM, configurable size/rate in the library | AirConnect bridges AirPlay into UPnP and Chromecast (the other direction) |
| [libairptp](https://github.com/owntone/libairptp) | C, MIT **[V]** | — | PTP master for senders | — | Port 319/320 helper |
| pair_ap (in OwnTone, shairport-sync) | C, MIT **[V]** | — | HomeKit pairing client and server | — | SRP via csrp |
| Music Assistant `cliairplay` | C, GPL-3, OwnTone-derived **[D]** ([search result](https://github.com/orgs/music-assistant/repositories)) | yes | yes: "native AirPlay 2, PTP, and MediaRemote" (2.10 nightly) **[D]** | not checked | Built for Music Assistant |

- **No open-source sender implementing buffered type 103 (or 24/48 ALAC) was found** **[I]**. Searches turned up only
  receivers (openairplay2, goplay2, airplay2-receiver).
- The receiver side is fully documented in code: shairport-sync's
  [`ap2_buffered_audio_processor.c`](https://github.com/mikebrady/shairport-sync/blob/master/ap2_buffered_audio_processor.c)
  covers TCP framing, ChaCha20 per packet, SSRC switching and flush semantics **[V]**.
- emanuelecozzi.net's "AirPlay 2 Internals" (cited in shairport-sync comments) couldn't be fetched: expired TLS
  certificate.

---

## 3. macOS-native paths

### 3.1 The Core Audio AirPlay device (today's route)

- What's known:
  - Vespertine already treats it as not bit-perfect: "AirPlay streams at 44.1 kHz; the receiver controls the final
    format" (`DeviceProfile.swift` l.96–99) **[V]**.
  - shairport-sync's release notes describe "using Shairport Sync as the Sound Output on a Mac" as a *Realtime Audio
    stream* (RELEASENOTES.md, issue #1633) **[D]**.
  - The only realtime format shairport-sync offers is ALAC/S16/44100/2 **[V]**.
  - **So Mac sound output to moOde is ALAC 16/44.1** **[I, strong]**.
- **A third-party app can't choose the codec, depth or buffered mode.** It can only choose the device and feed it
  float PCM **[I]**.
- **Can it be bit-perfect for a 16/44.1 file?**
  - Float carries 16-bit samples exactly, so it *might* be, if macOS applies no gain, mixing, dither or SRC.
  - We can't see this from the Mac.
  - **It can be measured on the receiver** (§3.4). This is a cheap test worth doing first (Phase 0), because if it
    passes, the native route is already "bit-perfect as sent" for CD sources and the RAOP work brings less.

### 3.2 AVPlayer and AVRoutePickerView (Apple's AirPlay 2 "long-form" path)

- On macOS, `AVRoutePickerView.player` is an **`AVPlayer`** (macOS 10.15+, `API_UNAVAILABLE(ios, …)`, AVKit
  `AVRoutePickerView.h` l.96) **[V]**. So the per-app AirPlay 2 route on macOS works through an AVPlayer.
- `AVAudioSession.routeSharingPolicy` (`.longFormAudio`) is not available on macOS. Apple's doc JSON lists iOS, iPadOS,
  tvOS, watchOS, visionOS and Mac Catalyst only **[V]**.
- `AVSampleBufferAudioRenderer` exists on macOS 10.13+ **[V]**, but on macOS it can only be pointed at a Core Audio
  device (`audioOutputDeviceUniqueID`). It has no route-picker hook **[V]** (SDK headers). WWDC23 names
  AVSampleBufferAudioRenderer + AVSampleBufferRenderSynchronizer as the custom-pipeline way to get enhanced buffering
  **[D]**, but the session shows it only for iOS.
- **Format sent:** Apple doesn't document it. The only statement is "intelligent use of Lossless playback for iOS"
  **[D]**. Whether AVPlayer on a Mac ever sends ALAC 24/48 from a third-party app is **unknown**. It can be tested with
  the receiver readback in §3.4.
- **Reuse idea:** AVPlayer could play the UPnP design's processed-mode URL (`http://127.0.0.1:<port>/media/<token>.flac`).
  Vespertine's EQ and room correction would still apply, and Apple would do the AirPlay 2 side, including HomePod and
  Apple TV, legitimately **[I]**.
- **What's lost on this path:** control of SRC and dither, AVPlayer's own position and gapless behaviour, and any
  "bit-perfect" claim. It is a "compatible" path, not a quality one.

### 3.3 AVRouteDetector

- `AVRouteDetector` (macOS 10.13+) only reports *whether* routes exist **[V]**. It doesn't list receivers or formats.

### 3.4 Verifying what is sent

From the Mac side, only our own sender lets us know what is sent (we build the packets).

On the receiver (moOde):

- **shairport-sync metadata** reports the stream (via its pipe, MQTT or D-Bus):
  - `sdsc`: source format, e.g. `"ALAC/44100/S16_LE/2"`
  - `odsc`: output format, e.g. `"44100/S16_LE/2"`
  - `styp`: `"Classic"` / `"Realtime"` / `"Buffered"`
  
  Source: [METADATA CODES.md](https://github.com/mikebrady/shairport-sync/blob/master/METADATA%20CODES.md) **[D]**,
  `player.c` l.1066, l.3408 **[V]**.
- **A bit-exact test:** use the `pipe`/`stdout` backend, where "No interpolation is done", and compare a checksum of
  the PCM with the source's decoded PCM. This settles "bit-perfect as sent" for every phase, and for the Core Audio and
  AVPlayer routes **[I]**.
- **What the DAC actually runs at:** ALSA `/proc/asound/card*/pcm0p/sub0/hw_params` on the Pi **[I]** (a standard
  Linux interface).

---

## 4. Best possible per current file: decision table

Assumptions:

- No EQ, room correction, digital volume or ReplayGain. If any of those is on, the row becomes "processed" with the
  same target format and the badge `PROCESSED · EQ` and so on, as in the UPnP spec.
- **SRC:** Vespertine's `AVAudioConverter` with `AVSampleRateConverterAlgorithm_Mastering` at maximum quality
  (ARCHITECTURE.md §Decode) **[V]**.
- **Reducing to 16 bits:** TPDF dither at 16 bits, as the render chain already does at the DAC word length
  (ARCHITECTURE.md §Render) **[V]**.
- **No noise shaping.** It isn't in the engine today, and plain TPDF is the honest default.

Receiver columns:

- **RAOP-only**, and AirPlay 2 receivers that only allow realtime (= what every sender has today).
- **AirPlay 2 shairport-sync with buffered ALAC 24/48** (`lossless_mode` on, which is the default).
- **HomePod / Apple TV:** best effort, see §1.6, §2.2 and §6.

| Source | RAOP-only / AirPlay 2 realtime | AirPlay 2 buffered 24/48 (shairport-sync) | HomePod / Apple TV |
|---|---|---|---|
| **16/44.1 stereo** | ALAC 16/44.1, samples as decoded. **Bit-perfect as sent.** `BIT-PERFECT · 16/44.1 SENT` | the same, over RAOP or realtime. Don't resample to 48. `BIT-PERFECT · 16/44.1 SENT` | AirPlay 2 realtime ALAC 16/44.1 if accepted: same badge. Otherwise unavailable |
| **16/48** | SRC to 44.1, 16-bit with TPDF. Lossy conversion (resampled and requantised). `RESAMPLED · 16/44.1 SENT` | ALAC 24/48 with the 16-bit samples padded (exact). `BIT-PERFECT · 16/48 SENT` (sent as 24-bit) | realtime: `RESAMPLED · 16/44.1 SENT` |
| **24/44.1** | 16/44.1 with TPDF dither (rate kept, depth reduced). `DITHERED · 16/44.1 SENT` | **choice** (setting "AirPlay 24-bit at 44.1 kHz"): **a)** 24/48 via mastering SRC (keeps 24-bit resolution, error far below the 16-bit floor) = `RESAMPLED · 24/48 SENT` (proposed default); **b)** 16/44.1 dithered = `DITHERED · 16/44.1 SENT` | `DITHERED · 16/44.1 SENT` |
| **24/48** | SRC to 44.1 + dither to 16. `RESAMPLED · 16/44.1 SENT` | ALAC 24/48. **Bit-perfect as sent.** `BIT-PERFECT · 24/48 SENT` | `RESAMPLED · 16/44.1 SENT` (24/48 only if buffered is proven to work there) |
| **24/88.2 / 176.4** | SRC (integer 2:1 / 4:1) to 44.1 + dither 16. `RESAMPLED · 16/44.1 SENT` | SRC to 48, 24-bit. `RESAMPLED · 24/48 SENT`. The non-integer ratio is not an issue for a mastering-quality SRC **[I]** | `RESAMPLED · 16/44.1 SENT` |
| **24/96 / 192 (and 352.8/384)** | SRC to 44.1 + dither. `RESAMPLED · 16/44.1 SENT` | SRC to 48, 24-bit. `RESAMPLED · 24/48 SENT` | `RESAMPLED · 16/44.1 SENT` |
| **32-bit integer / float** | as 24-bit at its rate, but 32→16 dithered. `DITHERED`/`RESAMPLED · 16/44.1 SENT` | 24/48: a 32→24 reduction always needs TPDF at 24 bits. `RESAMPLED`/`DITHERED · 24/48 SENT` | as RAOP |
| **DSD (64–512)** | the engine's DSD→PCM, then SRC to 44.1 + dither 16. `DSD→PCM · 16/44.1 SENT` | DSD→PCM, then 48 kHz 24-bit. `DSD→PCM · 24/48 SENT` | `DSD→PCM · 16/44.1 SENT` |
| **Multichannel PCM (5.1/7.1)** | stereo downmix (the engine's), 16/44.1. `DOWNMIX · 16/44.1 SENT` | **a)** stereo downmix 24/48 lossless after processing: `DOWNMIX · 24/48 SENT` (default); **b)** optional AAC 5.1/7.1 48 kHz (AudioConverter AAC encode): `LOSSY · AAC 5.1 SENT` | stereo downmix as RAOP. Multichannel AirPlay to HomePod/Apple TV needs Apple's path (§3.2) |
| **Dolby Atmos (DD+ JOC)** | bed decode (5.1, no heights; ARCHITECTURE.md §Atmos) → stereo downmix → 16/44.1. `DOWNMIX · 16/44.1 SENT` + note "Atmos objects aren't sent over AirPlay" | the same at 24/48, or AAC 7.1 of the bed (lossy) | Only Apple's own AVPlayer path could carry Atmos. Not offered |
| **Lossy sources (AAC, MP3, Opus)** | decoded; 44.1 sources go bit-exact as decoded PCM, others SRC. `SENT AS DECODED · 16/44.1` (never "bit-perfect"; the decode is lossy) | same idea at 24/48 | same |

Notes:

- **"BIT-PERFECT · … SENT"** follows the UPnP design's `isUntouched` semantics. `SignalPath.isBitPerfect` stays
  **false** for every AirPlay path, so the badge never equals plain `BIT-PERFECT` (VERIFICATION.md: never claim what
  you can't check) **[V]**.
- **The signal-path note** must add: "AirPlay receivers keep in step with this Mac's clock by adding or removing
  samples, and may apply their own volume and resampling. What reaches the DAC can't be seen from here." On moOde, tell
  the user how to check `sdsc`/`odsc`.
- **The "16-bit at 44.1" floor is real loss** for 24-bit material: about 96 dB of dynamic range, with dither noise. The
  UI should say "dithered to 16-bit", not hide it.
- **Why 24/48 by default for 24/44.1:** a mastering-grade SRC from 44.1 to 48 keeps 24-bit resolution with errors far
  below the 16-bit noise floor, whereas going to 16 bits throws resolution away **[I]**. Some purists prefer the rate
  kept, so offer the setting.

---

## 5. Reuse of the UPnP infrastructure

| UPnP piece (spec §) | Reuse for AirPlay | Change needed |
|---|---|---|
| `RendererPlayback` façade: an engine-shaped object that publishes `EngineSnapshot`/`EngineEvent`, with `PlayerController` switching backends | **Reuse the pattern** as `AirPlayPlayback` | The sender owns the clock: position = frames sent − latency, no polling. Pause = FLUSH; seek = FLUSH + new RTP timeline |
| `NetworkRender` (VespertineAudio): offline decode → convert → render chain (gain, EQ, room correction, TPDF) yielding Int32 frames | **Core reuse.** This is the PCM tap | Needs a **target format parameter** (44.1/16 or 48/24) in place of "source rate, 24-bit". The `FormatPlanner` "virtual device" idea already fits: plan to a virtual 2-ch device at 44100 Hz, 16-bit integer, so SRC and dither are the engine's own. **Pacing:** NetworkRender runs faster than real time, so the sender needs a ring and a real-time RTP pacer (352 frames every 7.98 ms) |
| `RendererMode.decide` (pass-through vs processed with reasons) | Reuse the *reasons* (`.equalizer`, `.roomCorrection`, `.volume`, `.replayGain`) | No file pass-through mode: AirPlay always carries PCM frames, so "bit-perfect" means *decoded samples sent unchanged* at a matching format. Add reasons `.resampled(to:)`, `.dithered(to:)`, `.downmix`, `.dsdToPCM` |
| `DeviceProfile.networkRenderer`, `SignalPath.renderer: RendererStage`, `isUntouched`, `statusLine` "… SENT" | **Reuse directly** with `protocolName` "AirPlay" / "AirPlay 2" | `sentCodec` "ALAC", `sentSampleRate/BitDepth` from the chosen target. Add `warnings` for receiver-side sync and volume |
| Discovery (`RendererDiscovery` with SSDP) | **Swap the transport:** `NWBrowser` for Bonjour `_raop._tcp` and `_airplay._tcp`, TXT parsing (`cn`, `et`, `ss`, `sr`, `features`, `flags`, `pk`) | Merge RAOP and AirPlay 2 records by `deviceid`/MAC. Exclude this Mac's own AirPlay receiver |
| Picker "Network players" section, `RendererDetails`, volume lock UX | **Reuse**: rows with symbol `airplay.audio`; details show protocol, formats accepted (`supportedFormats` from `/info`), pairing state | PIN entry sheet (Apple TV); Keychain storage of pairing keys |
| `HTTPServer`/`MediaServer` | Not needed for RAOP or AirPlay 2 (push). Useful only for the AVPlayer experiment (§3.2) | — |
| Test approach (fakes on 127.0.0.1, sample-exact checks) | **Reuse:** a `FakeAirPlayReceiver` that answers RTSP, decrypts, decodes ALAC with AudioConverter and compares samples to the source | Golden tests for SDP/plist, AES/ChaCha vectors, SRP test vectors (RFC 5054) |

New code:

- **RTSP client** with the AirPlay quirks: CSeq, `Apple-Challenge`, `DACP-ID`, `Active-Remote`, `X-Apple-*` headers,
  and an encrypted framing mode for AirPlay 2.
- **RTP sender:** audio, sync and retransmit over `NWConnection` UDP; TCP for buffered.
- **NTP timing responder** (RAOP).
- **ALAC framing.** Verbatim (uncompressed) ALAC frames are lossless, simplest, and as OwnTone does. Compressed ALAC
  can come later through `AudioConverter` (`kAudioFormatAppleLossless`). Check that it accepts 352-frame packets;
  otherwise use Apple's open-source ALAC encoder, Apache-2.0 **[I]**.
- **Crypto:**
  - RAOP: RSA-OAEP with the public key, and AES-128-CBC (Security / CommonCrypto).
  - AirPlay 2: pair-setup/verify with CryptoKit (Curve25519, Ed25519, ChaChaPoly, HKDF-SHA512) plus **SRP-6a 3072**.
    CryptoKit has no SRP, so that means a big-integer implementation or a small vendored library.
- **PTP master** (AirPlay 2): IEEE 1588 Sync, Follow_Up and Announce on 319/320, as libairptp does.
- **bplist** with `PropertyListSerialization`.
- **Volume and metadata:** DMAP for title, artist and album; artwork; progress.

---

## 6. Recommendation

### 6.1 Phases

**Phase 0: measure (2–3 days).**

- On moOde, set up a shairport-sync `pipe` backend, or read `sdsc`/`odsc`.
- Play test files from Vespertine through today's **Core Audio AirPlay device**. Optionally also through an
  **AVPlayer + AVRoutePickerView** prototype playing the processed FLAC URL.
- Checksum the PCM to learn whether macOS sends 16/44.1 bit-exact and what AVPlayer sends (AAC? ALAC 24/48?).
- Update `DeviceProfile`'s AirPlay note to match what was measured.
- If AVPlayer turns out to send ALAC 24/48 to shairport-sync, the cost-benefit of Phase 2 changes.

**Phase 1: RAOP sender, ALAC 16/44.1 (about 3–4 weeks for one experienced developer, with tests).**

- Scope: discovery; RTSP; unencrypted plus RSA/AES; verbatim ALAC; NTP timing; sync and retransmit; volume as
  metadata; DMAP metadata; gapless within one stream; `AirPlayPlayback` façade; `NetworkRender` target format; badges;
  picker; fake receiver tests.
- Delivers `BIT-PERFECT · 16/44.1 SENT` for CD sources, and honest converted badges for everything else.
- Works with moOde (classic and AirPlay 2 builds), AirPort Express, and most third-party speakers and AVRs.
- Legacy Apple TV PIN pairing: +1 week, optional.

**Phase 2: AirPlay 2 to shairport-sync (about 6–10 weeks; experimental).**

- **2a, realtime type 96 ALAC 16/44.1:** transient pairing (pair_ap as the reference), encrypted RTSP, SETUP plists,
  ChaCha20 audio, **PTP master**, feedback. OwnTone proves this works against shairport-sync 5.x **[D]**. It brings
  reliability, grouping and pairing, but no extra quality. About 4–5 weeks.
- **2b, buffered type 103 ALAC 24/48:** TCP data channel, per-packet ChaCha20, SSRC `0x15000000`, flush and anchor
  semantics, modelled on shairport-sync's `ap2_buffered_audio_processor.c` **[V]**. About 2–5 weeks, **high
  uncertainty**: no open-source sender to copy.
  - Delivers `BIT-PERFECT · 24/48 SENT` and 16/48 sources sent unchanged.
  - Delivers `RESAMPLED · 24/48 SENT` for hi-res.
- **Gate:** the buffered stream to moOde passes the pipe-backend checksum test.

**Phase 3: HomePod / Apple TV (open-ended; don't commit).**

- Only after Phase 2 is stable, and only if OS 27 behaviour allows it.
- Transient pairing worked for OwnTone. After OS 27 there are reports of refused AirPlay 2 setups and silent AirPlay 1
  (§1.6).
- Whether a non-Apple buffered ALAC 24/48 stream is accepted by HomePod is **unknown**. The fallback for Apple
  receivers is the AVPlayer route (§3.2), which is legitimate and maintained by Apple, but not bit-perfect-capable.

### 6.2 Risks

- **Protocol churn.** Apple changes receivers yearly (tvOS/HomePod OS 27 broke Roon and, reportedly, Airfoil in
  September 2026) **[D]**. shairport-sync and OwnTone also track Apple senders and receivers, which is our early warning.
- **Apple blocking.** Apple could require FairPlay or MFi authentication (`/auth-setup`, `et=4`) for all senders.
  pyatv notes MFi-authentication devices "might require an authentication step… just send request and ignore response"
  today **[D]**. That can change.
- **PTP port conflicts** on macOS (319/320) with the system AirPlay stack **[I]**.
- **Receiver-side alteration** (sync stuffing, software volume, resampling to the DAC rate) is outside our control. The
  badges handle it honestly; the user gets setup advice: hardware mixer or `ignore_volume_control`,
  `disable_synchronization`, `output_rate`/`output_format` "auto".
- **Licensing:**
  - Vespertine is GPL-3.
  - OwnTone (GPL-2.0-or-later) and Music Assistant's cliairplay (GPL-3) can be studied or ported under GPL-3.
  - pyatv, libraop, AirConnect, libairptp and pair_ap are MIT, so compatible.
  - shairport-sync is per-file; read it as documentation and port ideas, not code, unless the file's license is checked.
- **Legal** (not legal advice) **[I]**:
  - RAOP and AirPlay 2 are reverse-engineered, unpublished protocols, implemented for more than a decade by
    shairport-sync, OwnTone, pyatv, Roon and Airfoil without known enforcement against audio-only senders.
  - Interoperability reverse engineering has statutory cover: US 17 U.S.C. §1201(f), EU Directive 2009/24/EC Art. 6.
  - Implementing or bypassing **FairPlay** is the part that could be framed as circumventing a technical protection
    measure. **The plan never touches FairPlay**, and audio to these receivers doesn't need it **[V]**.
  - "AirPlay" is an Apple trademark: describe it as "AirPlay-compatible output", don't claim certification.
  - Mac App Store review is a separate risk if Vespertine is ever distributed there.

### 6.3 What to tell the owner plainly

> AirPlay can't carry 192 kHz, or anything above 48 kHz. AirPlay 2 and your moOde (shairport-sync) top out at 24-bit /
> 48 kHz lossless, and only over the "buffered" AirPlay 2 mode, which no free sender implements yet; plain AirPlay
> (and AirPlay 2's realtime mode) is 16-bit / 44.1 kHz. What Vespertine can do well:
>
> - send CD-quality files **exactly as they are**;
> - later, send 24/48 files exactly as they are;
> - convert everything else with the same mastering-grade resampler and dither the app uses for your DAC, saying so
>   on the badge.
>
> Because the Mac's clock drives AirPlay, moOde may still nudge the audio to stay in sync, and it may apply its own
> volume. So we can promise "bit-perfect as sent", and show you how to confirm on the Pi that nothing changed it after
> that. For hi-res, your new UPnP/OpenHome output is the right path: moOde pulls the original file, so it stays 24/192
> and untouched.

### 6.4 The single most important caveat

**AirPlay is push-timed by the sender.** Even a sample-exact stream gets re-timed by the receiver (frames inserted or
dropped to track the Mac's clock), unless synchronisation is turned off on the receiver. So AirPlay can never earn a
DAC-level bit-perfect claim. Only "bit-perfect as sent, 16/44.1 (or 24/48)" is possible. For moOde, the UPnP/OpenHome
output remains the bit-perfect hi-res path, and AirPlay is a convenience and compatibility output.

---

## Sources

- shairport-sync: [AIRPLAY2.md](https://github.com/mikebrady/shairport-sync/blob/master/AIRPLAY2.md),
  [rtsp.c](https://github.com/mikebrady/shairport-sync/blob/master/rtsp.c),
  [rtp.c](https://github.com/mikebrady/shairport-sync/blob/master/rtp.c),
  [player.c](https://github.com/mikebrady/shairport-sync/blob/master/player.c),
  [player.h](https://github.com/mikebrady/shairport-sync/blob/master/player.h),
  [ap2_buffered_audio_processor.c](https://github.com/mikebrady/shairport-sync/blob/master/ap2_buffered_audio_processor.c),
  [scripts/shairport-sync.conf](https://github.com/mikebrady/shairport-sync/blob/master/scripts/shairport-sync.conf),
  [METADATA CODES.md](https://github.com/mikebrady/shairport-sync/blob/master/METADATA%20CODES.md),
  [RELEASENOTES.md](https://github.com/mikebrady/shairport-sync/blob/master/RELEASENOTES.md),
  [LICENSES](https://github.com/mikebrady/shairport-sync/blob/master/LICENSES)
- OwnTone: [src/outputs/airplay.c](https://github.com/owntone/owntone-server/blob/master/src/outputs/airplay.c),
  [src/outputs/raop.c](https://github.com/owntone/owntone-server/blob/master/src/outputs/raop.c),
  [ChangeLog](https://github.com/owntone/owntone-server/blob/master/ChangeLog),
  [docs/audio-outputs/airplay.md](https://github.com/owntone/owntone-server/blob/master/docs/audio-outputs/airplay.md),
  [libairptp](https://github.com/owntone/libairptp)
- pyatv: [protocols.md](https://github.com/postlund/pyatv/blob/master/docs/documentation/protocols.md),
  [supported_features.md](https://github.com/postlund/pyatv/blob/master/docs/documentation/supported_features.md),
  [raop/protocols/airplayv2.py](https://github.com/postlund/pyatv/blob/master/pyatv/protocols/raop/protocols/airplayv2.py)
- libraop: [README](https://github.com/philippe44/libraop), [raop_client.c](https://github.com/philippe44/libraop/blob/master/src/raop_client.c);
  [AirConnect](https://github.com/philippe44/AirConnect)
- Apple: [About lossless audio in Apple Music (118295)](https://support.apple.com/en-us/118295);
  [WWDC23 10238 Tune up your AirPlay audio experience](https://developer.apple.com/videos/play/wwdc2023/10238/);
  [AVRoutePickerView](https://developer.apple.com/documentation/avkit/avroutepickerview),
  [AVRouteDetector](https://developer.apple.com/documentation/avfoundation/avroutedetector),
  [AVSampleBufferAudioRenderer](https://developer.apple.com/documentation/avfoundation/avsamplebufferaudiorenderer);
  macOS SDK `AVKit/AVRoutePickerView.h`
- OS 27 breakage: [Roon community thread (Sept 2026)](https://community.roonlabs.com/t/ios-27-apple-homepods-fail-to-stream-sound-from-roon-airplay-ref-9ki1fy-hotfix-released/324917),
  [Roon Rock thread](https://community.roonlabs.com/t/roon-rock-airplay-issues-post-homepod-os27-update-ref-pnhpyc/324906)
- Music Assistant cliairplay: [music-assistant org](https://github.com/orgs/music-assistant/repositories),
  [2.10 nightly notes](https://newreleases.io/project/github/music-assistant/server/release/2.10.0.dev2026072204)
- Vespertine: `Packages/VespertineKit/Sources/VespertineAudio/DeviceProfile.swift`, `docs/VERIFICATION.md`,
  `docs/ARCHITECTURE.md`; UPnP design `Vespertine-trackC/docs/superpowers/specs/2026-11-13-upnp-output-design.md` and
  plan `…/plans/2026-11-13-upnp-output.md` (read-only)
