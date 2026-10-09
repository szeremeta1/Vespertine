# Signal-integrity claims

Every externally visible claim Vespertine makes about what happens to the audio between the file and the device, as of `main` at `98cad1a`.

Sources read: `README.md`, `docs/VERIFICATION.md`, `docs/FEATURES.md`, `docs/ARCHITECTURE.md`, `docs/ANALYSIS.md`, `site/index.html` and `Packages/VespertineKit/Sources/VespertineAudio/SignalPath.swift`.

Each claim lists:

- **Text** lines: the exact words and where they are (`file:line`). `tools/check_registry.py` checks that each quoted string still appears on that line, so a doc edit that changes a claim fails CI until this file is updated.
- **Property:** what you could observe if the claim is true.
- **Governed by:** `spec` when a published standard defines the behaviour; `vespertine-rule` when the behaviour is Vespertine's own definition (the BIT-PERFECT conditions, for example); `oracle` when the only available check is agreement with another implementation; `heuristic` when the claim is explicitly an estimate.
- **Route:** how this harness checks it. `spec-traced` means requirement records plus blind A/B/C tests (see `REPORT.md`); `oracle` means comparison with an independent implementation; `hardware` means a procedure in `hardware/`; `inventory` means recorded here but not tested by this harness, with the reason.

Requirement records point back to these anchors (`claim: CLAIMS.md#<anchor>`).

---

## BIT-PERFECT

### CL-BP-01 <a id="bp-definition"></a>The badge means every sample arrives unaltered

- **Text:** `docs/VERIFICATION.md:18` — "Vespertine shows **BIT-PERFECT** only when every sample of the file reaches the device's input unaltered."
- **Text:** `Packages/VespertineKit/Sources/VespertineAudio/SignalPath.swift:41` — "/// True only when every sample reaches the DAC unaltered."
- **Text:** `README.md:33` — "BIT-PERFECT appears only when the [conditions in code](Packages/VespertineKit/Sources/VespertineAudio/SignalPath.swift) are met"
- **Property:** two separate things. (a) The verdict is true only when every listed condition holds (CL-BP-02 to CL-BP-13). (b) When it is true, the words the render stage hands to Core Audio equal the decoded samples. The harness cannot see past the HAL; what the device does with the words is covered only by the loopback procedure.
- **Governed by:** vespertine-rule for (a). For (b), the exactness of each data path (CL-FLOAT-01, CL-INT-01, CL-DOP-02) is measurable without a standard.
- **Route:** spec-traced (verdict group, float group, integer group, DoP group); hardware (`hardware/LOOPBACK.md`).

### CL-BP-02 <a id="bp-pcm-native-rate"></a>PCM at its own rate, nothing resampled or converted

- **Text:** `docs/VERIFICATION.md:20` — "**The source is PCM** and plays at its own sample rate. Nothing is resampled and no DSD is converted to PCM."
- **Text:** `docs/ARCHITECTURE.md:90` — "For PCM: the source is lossless, it isn't resampled or converted from DSD"
- **Property:** the PCM verdict is false when the source is lossy or DSD, when the plan resamples, when DSD is converted to PCM, or when the device rate read back differs from the source rate.
- **Governed by:** vespertine-rule.
- **Route:** spec-traced (verdict group).

### CL-BP-03 <a id="bp-readback"></a>The device rate is read back, not assumed

- **Text:** `docs/VERIFICATION.md:21` — "Vespertine switches the device's nominal rate and reads it back from Core Audio. It doesn't trust its own request."
- **Text:** `docs/VERIFICATION.md:42` — "The device values are read from Core Audio after playback starts:"
- **Text:** `site/index.html:297` — "The signal path reads back what Core Audio actually did: the device's nominal rate, its physical format and who holds it."
- **Property:** the rate, physical format and hog owner that the verdict uses are the values Core Audio returned (`kAudioDevicePropertyNominalSampleRate`, `kAudioStreamPropertyPhysicalFormat`, `kAudioDevicePropertyHogMode`). If a readback fails, the verdict must not fall back to what Vespertine asked for.
- **Governed by:** vespertine-rule; the meaning of each property comes from Apple's Core Audio headers (spec for the property semantics only).
- **Route:** spec-traced (verdict group: a failed or stale readback must not yield BIT-PERFECT); source review recorded in `FINDINGS.md` (F-01). The readback itself happens in `OutputSession`, which needs a real device; see `hardware/LOOPBACK.md` step P1.

### CL-BP-04 <a id="bp-word-length"></a>The physical format holds the whole sample

- **Text:** `docs/VERIFICATION.md:23` — "An integer DAC needs at least the file's bit depth."
- **Text:** `docs/VERIFICATION.md:24` — "A float device needs a full 32-bit float."
- **Text:** `docs/VERIFICATION.md:25` — "In the normal float pipeline, up to 24 bits pass through exactly. 32-bit integer files need **integer mode**"
- **Text:** `docs/ARCHITECTURE.md:90` — "the source is at most 24-bit (32-bit with integer mode, which skips the Float32 step), and the device's physical format can hold it (an integer format at least as deep as the source, or 32-bit float)."
- **Property:** PCM verdict false when source bits > 24 without integer mode, > 32 with it, when an integer physical format is narrower than the source, or when a float physical format is narrower than 32 bits.
- **Governed by:** vespertine-rule.
- **Route:** spec-traced (verdict group).

### CL-BP-05 <a id="bp-no-gain"></a>No software gain

- **Text:** `docs/VERIFICATION.md:26` — "**No gain is applied anywhere in software.**"
- **Text:** `docs/VERIFICATION.md:28` — "Digital volume must be off or at exactly 0 dB."
- **Text:** `docs/VERIFICATION.md:29` — "ReplayGain must be off or at 0 dB."
- **Text:** `docs/ARCHITECTURE.md:88` — "No software gain is applied (neither ReplayGain nor digital volume)."
- **Property:** verdict false whenever digital volume or ReplayGain is non-zero, or an equalizer preset is applied.
- **Governed by:** vespertine-rule.
- **Route:** spec-traced (verdict group).

### CL-BP-06 <a id="bp-channels"></a>No spatial or channel processing

- **Text:** `docs/VERIFICATION.md:30` — "**No spatial or channel processing is applied.** The device has at least as many channels as the file."
- **Text:** `docs/ARCHITECTURE.md:87` — "No Spatial Audio rendering or downmix."
- **Property:** verdict false when Spatial Audio is on, when the plan's channel count differs from the source's, or when the device has fewer channels than the source.
- **Governed by:** vespertine-rule.
- **Route:** spec-traced (verdict group).

### CL-BP-07 <a id="bp-no-mixing"></a>Exclusive, or nothing else playing

- **Text:** `docs/VERIFICATION.md:32` — "Either Vespertine has the device to itself (exclusive \"hog\" mode),"
- **Text:** `docs/VERIFICATION.md:33` — "or no other app is playing to it at the same moment."
- **Text:** `docs/VERIFICATION.md:124` — "Vespertine looks for this about once a second, through Core Audio's list of processes that are playing to the device (`DeviceControl.otherProcessesPlaying`), and drops the badge when it finds one."
- **Text:** `docs/ARCHITECTURE.md:86` — "The device is held exclusively, or (shared mode) no other process is currently sending audio to it (Core Audio process objects, checked about once a second)."
- **Property:** verdict false when the device is not held exclusively and another process is playing to it. "Held exclusively" means the hog-mode owner read back from Core Audio is Vespertine's process ID.
- **Governed by:** vespertine-rule; hog-mode semantics from Apple's `AudioHardware.h`.
- **Route:** spec-traced (verdict group). The once-a-second polling and its blind spots are inventory only (documented limit, `docs/VERIFICATION.md:124`).

### CL-BP-08 <a id="bp-device-class"></a>Bluetooth, AirPlay, speakers, virtual and aggregate devices are never BIT-PERFECT

- **Text:** `docs/VERIFICATION.md:35` — "Bluetooth devices never can, because macOS re-encodes the audio for the radio link. AirPlay can't either."
- **Text:** `docs/FEATURES.md:35` — "Speakers and virtual or aggregate devices are not labelled BIT-PERFECT."
- **Text:** `docs/ARCHITECTURE.md:85` — "The device profile can be bit-perfect (i.e. not Bluetooth or AirPlay)."
- **Property:** verdict false whenever the device class cannot be bit-perfect, regardless of every other condition.
- **Governed by:** vespertine-rule. How a device's class is detected (`DeviceProfile`) is inventory: it reads Core Audio transport types and the IORegistry, which need real devices.
- **Route:** spec-traced (verdict group, given the class); inventory (class detection).

### CL-BP-09 <a id="bp-airpods-usbc"></a>AirPods Max on USB-C

- **Text:** `docs/VERIFICATION.md:36` — "Vespertine detects the cable through the IORegistry (`DeviceProfile.swift`) and treats 48 kHz files as bit-perfect on that device."
- **Text:** `docs/FEATURES.md:47` — "AirPods Max on USB-C are recognized as a lossless 24-bit / 48 kHz device. Unprocessed 48 kHz tracks meet the app's bit-perfect conditions; other rates are converted to 48 kHz."
- **Text:** `site/index.html:198` — "48 kHz music plays bit-perfect"
- **Property:** with the cable connected, the device profile allows bit-perfect and 48 kHz unprocessed PCM gets the badge.
- **Governed by:** vespertine-rule, resting on Apple's description of the USB-C path. The docs already say a loopback cannot confirm it.
- **Route:** inventory. Detection needs the hardware, and no standard or loopback can check what happens inside the headphones.

### CL-BP-10 <a id="bp-damaged-frames"></a>Concealed SACD frames remove the badge

- **Text:** `docs/ARCHITECTURE.md:89` — "The decoder hasn't replaced any damaged frames of the track with silence (SACD images)."
- **Text:** `docs/ARCHITECTURE.md:31` — "which turns BIT-PERFECT off (\"DAMAGED FRAMES SILENCED\")"
- **Property:** verdict false, and the status reads DAMAGED FRAMES SILENCED, whenever the concealed-frame count is above zero.
- **Governed by:** vespertine-rule.
- **Route:** spec-traced (verdict group).

### CL-BP-11 <a id="bp-says-what"></a>Otherwise the badge says what changed

- **Text:** `docs/VERIFICATION.md:38` — "If any condition fails, the badge says what changed instead of BIT-PERFECT."
- **Text:** `README.md:33` — "when something changed the samples it says what"
- **Property:** when the verdict is false the status line is never BIT-PERFECT, NATIVE DSD · DoP or BITSTREAM · …, and it names a reason.
- **Governed by:** vespertine-rule.
- **Route:** spec-traced (verdict group: never a positive badge when a condition fails). Which reason is shown first is a UI choice and is inventory only.

### CL-BP-12 <a id="bp-dop-conditions"></a>DoP has its own badge and conditions

- **Text:** `docs/ARCHITECTURE.md:91` — "For DoP: the carrier runs at the planned rate with at least 24 bits."
- **Text:** `docs/VERIFICATION.md:38` — "DSD over DoP and the experimental Dolby/DTS bitstream path have their own badges and their own conditions"
- **Property:** NATIVE DSD · DoP only when the common conditions hold, the device rate read back equals the planned carrier rate, and the physical format is at least 24 bits.
- **Governed by:** vespertine-rule.
- **Route:** spec-traced (verdict group).

### CL-BP-13 <a id="bp-bitstream-conditions"></a>Bitstream conditions

- **Text:** `docs/ARCHITECTURE.md:64` — "Dolby and DTS-CD sources plan as mode `.bitstream`: exclusive, exact rate, integer ≥ 16-bit, no gain."
- **Property:** BITSTREAM · … only when the common conditions hold, the device rate read back equals the planned rate, and the physical format is integer and at least 16 bits.
- **Governed by:** vespertine-rule. Note: the docs say "exclusive" for the plan; the verdict's common condition accepts shared mode with no other app playing. Recorded as a gap in the requirement, not decided here.
- **Route:** spec-traced (verdict group).

---

## Equalizer

### CL-EQ-01 <a id="eq-label"></a>An active preset replaces BIT-PERFECT with EQUALIZER

- **Text:** `docs/FEATURES.md:81` — "An active preset that changes samples replaces BIT-PERFECT with EQUALIZER."
- **Text:** `site/index.html:215` — "when it's on, the signal path says EQUALIZER instead of BIT-PERFECT."
- **Text:** `README.md:37` — "when it is on the signal path says EQUALIZER."
- **Property:** with an equalizer preset applied, the verdict is false; and when no earlier reason applies (resampling, DSD → PCM, lossy source, mixing, device class, spatial, channels), the status line is EQUALIZER.
- **Governed by:** vespertine-rule.
- **Route:** spec-traced (verdict group).

### CL-EQ-02 <a id="eq-flat-is-none"></a>A preset that changes nothing counts as none

- **Text:** `docs/ARCHITECTURE.md:17` — "A preset that changes nothing counts as none, so playback stays bit-perfect"
- **Property:** a flat preset (all gains 0 dB, preamp 0 dB) is not passed to the render stage, so the samples are untouched and the verdict can be true.
- **Governed by:** vespertine-rule.
- **Route:** inventory. The decision is made in `PlaybackEngine`/`EQPreset` before the signal path is built; the verdict group covers what happens once a preset is reported as applied.

### CL-EQ-03 <a id="eq-not-dop"></a>EQ does not touch DoP or bitstream

- **Text:** `docs/FEATURES.md:83` — "EQ does not process DoP, system-rendered Atmos, or the experimental receiver bitstream path"
- **Property:** with DoP mode on in the render stage, an equalizer bank set on the context leaves the DoP words unchanged.
- **Governed by:** vespertine-rule.
- **Route:** spec-traced (DoP render group).

---

## Float path

### CL-FLOAT-01 <a id="float-24bit"></a>Every 24-bit value passes the float path unchanged at unity gain

- **Text:** `docs/VERIFICATION.md:57` — "the float path carries every possible 24-bit sample unchanged at unity gain"
- **Text:** `docs/ARCHITECTURE.md:14` — "integer PCM up to 24 bits maps exactly into Float32, which a unit test verifies sample-for-sample."
- **Text:** `docs/ARCHITECTURE.md:15` — "Gain of exactly 1.0 with no equalizer is a straight copy."
- **Text:** `docs/FEATURES.md:37` — "The float path preserves up to 24 significant bits."
- **Text:** `docs/ARCHITECTURE.md:136` — "Elsewhere Vespertine renders Float32, which is exact up to 24 bits."
- **Text:** `docs/VERIFICATION.md:25` — "In the normal float pipeline, up to 24 bits pass through exactly."
- **Property:** for each of the 2^24 values k in [-2^23, 2^23 − 1], the Float32 k / 2^23 written into the ring comes out of the render stage with the identical bit pattern, at unity gain with no equalizer, on every channel and at every position in a buffer. Separately, the int → Float32 mapping (Apple's `AVAudioConverter`) is exact and invertible for 24-bit input.
- **Governed by:** vespertine-rule. That Float32 holds every 24-bit integer exactly is arithmetic (a 24-bit significand), checked exhaustively rather than cited.
- **Route:** spec-traced (float group). The `AVAudioConverter` mapping runs on macOS only and is reported from the adapter tests.

### CL-FLOAT-02 <a id="float-rounds-wider"></a>Wider files are rounded in the float path

- **Text:** `docs/VERIFICATION.md:126` — "Files wider than 24 bits are rounded unless integer mode is on and the DAC offers a 32-bit integer format."
- **Property:** a 32-bit source in float mode never gets the BIT-PERFECT badge.
- **Governed by:** vespertine-rule.
- **Route:** spec-traced (verdict group).

---

## Integer mode

### CL-INT-01 <a id="int-32bit-words"></a>Integer mode passes every 32-bit word untouched, NaN patterns included

- **Text:** `docs/VERIFICATION.md:58` — "integer mode passes each 32-bit word through, including patterns that would be NaN as floats"
- **Text:** `docs/ARCHITECTURE.md:68` — "the IOProc copies them as integers, including ones that would be NaN as floats"
- **Text:** `docs/ARCHITECTURE.md:68` — "So 32-bit sources are bit-perfect."
- **Text:** `site/index.html:169` — "Integer mode sends 32-bit integers straight to DACs that take them."
- **Text:** `docs/FEATURES.md:37` — "It sends unprocessed PCM as integers, including 32-bit recordings that the normal Float32 path would round."
- **Property:** with integer mode on, every 32-bit word written to the ring (including all signalling and quiet NaN bit patterns, ±0, ±infinity and denormal patterns when read as Float32) comes out of the render stage with the same 32 bits, in order, per channel.
- **Governed by:** vespertine-rule.
- **Route:** spec-traced (integer group).

### CL-INT-02 <a id="int-24-top-bits"></a>A 24-bit source sits in the top 24 bits

- **Text:** `docs/VERIFICATION.md:59` — "A 24-bit source arrives as its samples in the top 24 bits, nothing added"
- **Property:** in integer mode a 24-bit sample s reaches the output as the Int32 s × 256, low byte zero.
- **Governed by:** vespertine-rule. The left-justification itself is what Core Audio's packed Int32 linear PCM means; the header documents the flags, not this mapping.
- **Route:** inventory. The mapping is done by Apple's `AVAudioConverter` in the decode stage; the existing `IntegerModeTests` cover it end to end on macOS.

### CL-INT-03 <a id="int-conditions"></a>When integer mode applies

- **Text:** `docs/FEATURES.md:37` — "Integer mode needs exclusive access and a DAC with a non-mixable 32-bit integer format."
- **Text:** `docs/ARCHITECTURE.md:68` — "no resampling, Spatial Audio, downmix, digital volume or ReplayGain, on a device with a non-mixable Int32 physical format."
- **Property:** the planner chooses integer samples only when every one of those conditions holds.
- **Governed by:** vespertine-rule.
- **Route:** inventory (planner logic; the verdict group covers the badge once integer mode is reported as applied).

---

## DSD over PCM (DoP)

### CL-DOP-01 <a id="dop-marker"></a>Markers alternate 0x05 / 0xFA

- **Text:** `docs/ARCHITECTURE.md:23` — "packs 16 bits per channel into each 24-bit frame with alternating 0x05/0xFA markers"
- **Text:** `docs/VERIFICATION.md:60` — "the markers a DAC looks for alternate correctly"
- **Property:** the top byte of each 24-bit DoP word is 0x05 or 0xFA, alternating every sample period, and the same on every channel within one sample period. Continues across a track change ("never two 0x05 in a row", `DSDTests`).
- **Governed by:** spec (DoP Open Standard 1.1).
- **Route:** spec-traced (DoP pack group, DoP render group).

### CL-DOP-02 <a id="dop-bits"></a>The DSD bits survive DoP packing exactly

- **Text:** `docs/VERIFICATION.md:60` — "DSF and DSDIFF DSD bits survive DoP packing exactly"
- **Text:** `docs/FEATURES.md:7` — "so it goes out over DoP bit for bit"
- **Property:** the low 16 bits of each DoP word carry 16 consecutive DSD bits of that channel, oldest bit in the most significant position, with no bit dropped, repeated or reordered.
- **Governed by:** spec (DoP Open Standard 1.1 for the frame layout; DSF 1.01 and DSDIFF 1.5 for which bit of a file byte is oldest).
- **Route:** spec-traced (DoP pack group).

### CL-DOP-03 <a id="dop-carrier-rate"></a>Carrier rate is a sixteenth of the DSD rate

- **Text:** `docs/ARCHITECTURE.md:23` — "so the DAC runs at a sixteenth of the DSD rate (176.4 kHz for DSD64)"
- **Property:** the planned device rate for DoP is the DSD bit rate divided by 16 (DSD64 → 176.4 kHz, DSD128 → 352.8 kHz, …).
- **Governed by:** spec for DSD64 and DSD128 (DoP 1.1 states both); vespertine-rule beyond that (DoP 1.1 says the method "can easily be extended" by raising the PCM rate, without listing rates).
- **Route:** spec-traced (rate group).

### CL-DOP-04 <a id="dop-passthrough"></a>DoP frames are never modified

- **Text:** `docs/ARCHITECTURE.md:15` — "DoP is always passthrough."
- **Text:** `docs/ARCHITECTURE.md:25` — "The frames themselves are never modified; a test checks they come out bit-identical."
- **Property:** with DoP on in the render stage, every 24-bit DoP word written to the ring comes out unchanged, in order, whatever the gain or equalizer setting.
- **Governed by:** vespertine-rule (a DAC can only recognise DoP whose markers arrive intact, which the DoP standard states).
- **Route:** spec-traced (DoP render group).

### CL-DOP-05 <a id="dop-plan"></a>DoP only when the DAC is marked capable and supports the carrier rate

- **Text:** `docs/ARCHITECTURE.md:23` — "DoP is planned only when the DAC is marked DoP-capable and supports that carrier rate; otherwise FFmpeg converts DSD to PCM at an eighth of the DSD rate and the planner resamples as needed."
- **Text:** `docs/FEATURES.md:43` — "DoP is off until enabled for a device because a non-DoP DAC would play the carrier as noise."
- **Property:** DoP mode only when the device is marked DoP-capable and lists the carrier rate; DSD → PCM otherwise, at DSD rate / 8.
- **Governed by:** vespertine-rule; DoP 1.1 §4 advises the host to check DSD capability first.
- **Route:** spec-traced (rate group).

### CL-DOP-06 <a id="dop-continuity"></a>A held DoP stream keeps its markers

- **Text:** `docs/VERIFICATION.md:91` — "The DAC should stay in DSD the whole time: no click, no missing ping."
- **Property:** whenever the render stage has no music to send in DoP mode (muted, rebuffering, ring empty), it sends DoP-marked DSD silence whose markers continue the alternation, so a receiver following DoP 1.1 §4 never sees a missing marker and never drops out of DSD.
- **Governed by:** spec for the receiver rule (DoP 1.1 §4: one missing marker returns the DAC to PCM) and the silence pattern (DSDIFF 1.5 §1.2); vespertine-rule for when idle frames are sent.
- **Route:** spec-traced (DoP render group); hardware (`vespertine-probe doptest`, listening test).

### CL-DOP-07 <a id="dop-file-bit-order"></a>DSF is LSB-first, DSDIFF MSB-first

- **Text:** `docs/ARCHITECTURE.md:23` — "DSF is planar and LSB-first, DSDIFF interleaved and MSB-first"
- **Property:** reading the same DSD from a DSF file and a DSDIFF file yields the same bit sequence per channel.
- **Governed by:** spec (DSF 1.01, DSDIFF 1.5).
- **Route:** inventory for this harness. The reader is FFmpeg's (`nff_read_dsd`); the existing `DSDTests` compare DSF and DSDIFF of the same DSD. The DoP pack contract takes MSB-first bytes, citing DSDIFF.

### CL-DOP-08 <a id="dop-indicator"></a>A DAC's DSD indicator proves the markers arrived

- **Text:** `docs/VERIFICATION.md:103` — "a DAC lights its DSD indicator for DoP only when the DoP marker bytes arrive untouched."
- **Property:** a lit DSD indicator rules out gain or resampling on the path (not every DSD bit).
- **Governed by:** spec (DoP 1.1 §4, receiver behaviour).
- **Route:** hardware (`hardware/LOOPBACK.md`, step D1).

---

## Receiver bitstream (IEC 61937)

### CL-IEC-01 <a id="iec-carrier-exact"></a>Frames go out byte for byte inside the carrier

- **Text:** `docs/VERIFICATION.md:61` — "Dolby/DTS frames go out byte for byte inside the IEC 61937 carrier"
- **Text:** `docs/ARCHITECTURE.md:64` — "The carriers are checked with FFmpeg's S/PDIF demuxer, which decodes them identically to the original files."
- **Text:** `docs/FEATURES.md:21` — "Carrier tests compare the data with FFmpeg's S/PDIF reader."
- **Property:** de-encapsulating the burst sequence returns the original Dolby/DTS frames, byte for byte, in order.
- **Governed by:** spec (IEC 61937-1/-3/-5, paywalled) for the burst format; oracle (FFmpeg `spdif` demuxer, and an independent parser written blind for this harness) for the check that is possible today.
- **Route:** oracle (`hardware/IEC61937-ORACLE.md`, IEC group). Spec records are blocked-on-source.

### CL-IEC-02 <a id="iec-ac3-burst"></a>Dolby Digital bursts

- **Text:** `docs/ARCHITECTURE.md:64` — "`BitstreamDecoder` wraps Dolby Digital frames in 1536-frame bursts at the stream's rate (Pd in bits)."
- **Property:** each AC-3 frame becomes one burst with preamble Pa, Pb, Pc (data type AC-3), Pd = frame length in bits, the frame's bytes as 16-bit words, zero padding to 1536 stereo frames.
- **Governed by:** spec (IEC 61937-1, IEC 61937-3; paywalled). The AC-3 frame size and bsmod come from ATSC A/52 (public).
- **Route:** blocked-on-source for the burst layout; oracle for payload identity.

### CL-IEC-03 <a id="iec-eac3-burst"></a>Dolby Digital Plus bursts

- **Text:** `docs/ARCHITECTURE.md:64` — "It groups Dolby Digital Plus frames into six-block bursts of 6144 frames at four times the rate (Pd in bytes, so HDMI only)."
- **Text:** `docs/FEATURES.md:21` — "Dolby Digital Plus needs HDMI."
- **Property:** E-AC-3 frames are grouped until they hold six audio blocks, then sent as one burst with Pd in bytes, padded to 6144 frames at 4× the stream rate.
- **Governed by:** spec (IEC 61937-3; paywalled) for the burst; ATSC A/52 Annex E (public) for blocks per frame.
- **Route:** blocked-on-source for the burst layout; oracle for payload identity.

### CL-IEC-04 <a id="iec-dtscd"></a>DTS CDs go out as stored

- **Text:** `docs/ARCHITECTURE.md:64` — "DTS CDs go out as stored."
- **Property:** in bitstream mode a DTS-CD file's 16-bit words reach the device unchanged.
- **Governed by:** vespertine-rule (the DTS CD format is not an IEC 61937 burst: it is the stream as the disc stores it).
- **Route:** inventory; same render-stage path as integer mode.

### CL-IEC-05 <a id="iec-scope"></a>Carrier checks don't establish receiver compatibility

- **Text:** `docs/VERIFICATION.md:14` — "Those checks do not establish receiver or interface compatibility."
- **Property:** scope limiter; nothing to test.
- **Governed by:** —
- **Route:** inventory.

---

## DTS CDs

### CL-DTSCD-01 <a id="dtscd-detect"></a>Detection needs two consecutive valid frames

- **Text:** `docs/ARCHITECTURE.md:50` — "it looks in the first 16,384 frames for two consecutive DTS frames, each with a valid core header and each where the one before it says (`ndts_find_stream`)"
- **Text:** `docs/FEATURES.md:19` — "Vespertine detects the stream and decodes it to 5.1, including CUE-split albums."
- **Property:** a 16-bit stereo file is treated as DTS only when a sync word with a valid core header is followed, exactly one frame later, by another one; ordinary PCM with a stray sync word is left alone.
- **Governed by:** spec for the sync words and core header fields (ETSI TS 102 114, public); vespertine-rule for "two consecutive frames" and the 16,384-frame window.
- **Route:** inventory for this run (see `REPORT.md`: not one of the seven groups the brief names; the ETSI text is cached for a follow-up).

### CL-DTSCD-02 <a id="dtscd-decode"></a>DTS-CD decode matches FFmpeg

- **Text:** `docs/ARCHITECTURE.md:52` — "A test checks the decode of a real DTS CD against FFmpeg's, bit for bit."
- **Property:** decoded PCM equals FFmpeg's `dca` decoder output.
- **Governed by:** oracle (and Vespertine uses FFmpeg's decoder, so this is a plumbing check, not an independent one).
- **Route:** inventory.

### CL-DTSCD-03 <a id="dtscd-positions"></a>Positions stay in carrier frames

- **Text:** `docs/ARCHITECTURE.md:52` — "So CUE indexes, seeks and durations are unchanged."
- **Property:** a CUE index in a DTS CD starts at the same carrier frame it names.
- **Governed by:** vespertine-rule.
- **Route:** inventory (existing `DTSTests`).

---

## SACD images

### CL-SACD-01 <a id="sacd-match"></a>Matched sacd_extract bit for bit on two real discs

- **Text:** `README.md:39` — "It matched sacd_extract bit for bit on two real discs."
- **Text:** `docs/FEATURES.md:7` — "Two real discs (The Dark Side of the Moon, Brothers in Arms) matched sacd_extract bit for bit"
- **Text:** `docs/ARCHITECTURE.md:31` — "Their TOCs, the raw DST frames, the decoded DSD of three tracks per area including adjacent ones, the DoP and PCM output, and random seeks were all identical."
- **Property:** for those images, TOC data, raw DST frames, decoded DSD, DoP and PCM output equal what `sacd_extract` produces.
- **Governed by:** oracle. The Scarlet Book is not public, so no spec citation is possible.
- **Route:** oracle (`hardware/SACD-ORACLE.md`, re-runnable on the maintainer's images).

### CL-SACD-02 <a id="sacd-dst"></a>DST decodes to the original DSD

- **Text:** `docs/FEATURES.md:7` — "DST is decoded to the original DSD"
- **Property:** DST decoding is lossless: decoding an encoded frame returns the exact DSD bytes it was made from.
- **Governed by:** oracle. DST is specified in ISO/IEC 14496-3 subpart 10 (paywalled) and the Scarlet Book (not public). DSDIFF 1.5 (public) defines the DST container chunks but not the decoding.
- **Route:** spec-traced framework with an oracle source (SACD/DST group): an independent decoder and mutated decoders run against frames from the repo's test encoder.

### CL-SACD-03 <a id="sacd-toc"></a>Master TOC location and copies

- **Text:** `docs/ARCHITECTURE.md:29` — "The Master TOC is at sector 510, with copies at 520 and 530"
- **Property:** the reader finds the Master TOC at sector 510 and falls back to 520 and 530.
- **Governed by:** Scarlet Book (not public). No public primary source; `sacd_extract` is the only reference.
- **Route:** oracle (`hardware/SACD-ORACLE.md`).

### CL-SACD-04 <a id="sacd-frames"></a>Frames are 1/75 s, 4704 bytes per channel

- **Text:** `docs/ARCHITECTURE.md:31` — "a plain one at exactly 4704 bytes per channel"
- **Text:** `docs/ARCHITECTURE.md:29` — "time codes of 1/75 s frames"
- **Property:** a plain DSD64 frame holds 37,632 DSD samples (4,704 bytes) per channel.
- **Governed by:** spec, through DSDIFF 1.5, which states the Super Audio CD frame length (1/75 s) and the resulting 37,632 samples at 64·fs. The SACD sector format itself is not public.
- **Route:** spec-traced (SACD/DST group, frame-size requirement).

### CL-SACD-05 <a id="sacd-areas"></a>Stereo and multichannel areas, DST or plain

- **Text:** `docs/FEATURES.md:7` — "stereo and multichannel areas, DST-compressed or plain, each song listed once with both versions"
- **Property:** both areas are found and played.
- **Governed by:** Scarlet Book (not public).
- **Route:** oracle.

### CL-SACD-06 <a id="sacd-readonly"></a>The image is never written

- **Text:** `docs/FEATURES.md:7` — "The image is read in place and never written to."
- **Property:** the image's bytes and modification time are unchanged after playback.
- **Governed by:** vespertine-rule.
- **Route:** oracle procedure step (hash before and after).

### CL-SACD-07 <a id="sacd-gapless"></a>Tracks join without a gap

- **Text:** `docs/ARCHITECTURE.md:29` — "the tracks join without a gap"
- **Property:** playing an area's tracks one after another yields the same DSD as the area in one piece.
- **Governed by:** vespertine-rule.
- **Route:** inventory (existing `SACDTests`); oracle procedure compares adjacent tracks.

---

## Sample rate

### CL-RATE-01 <a id="rate-native"></a>The DAC runs at the track's own rate

- **Text:** `docs/FEATURES.md:33` — "Vespertine switches the DAC to each track's native rate."
- **Text:** `README.md:35` — "Switches your DAC to each file's sample rate"
- **Text:** `site/index.html:166` — "Vespertine switches the device to each file's rate and resamples when the DAC cannot run it."
- **Property:** when the device lists the source rate and the policy is "match source", the planned device rate equals the source rate and nothing is resampled.
- **Governed by:** vespertine-rule.
- **Route:** spec-traced (rate group).

### CL-RATE-02 <a id="rate-planner-order"></a>Fallback order when the rate isn't offered

- **Text:** `docs/FEATURES.md:33` — "The planner prefers the same rate family, then a higher rate, then an integer divisor."
- **Text:** `docs/FEATURES.md:33` — "Per-device settings can match the source, use the device maximum, or force a rate."
- **Property:** when the source rate is not offered, the planner picks the smallest offered integer multiple of it, then the smallest offered rate above it, then the largest offered integer divisor, then the highest offered rate.
- **Governed by:** vespertine-rule. The docs' "same rate family, then a higher rate" is less precise than the code; the requirement records the gap.
- **Route:** spec-traced (rate group).

### CL-RATE-03 <a id="rate-handback"></a>The device is handed back on quit

- **Text:** `docs/FEATURES.md:39` — "At quit, each device is restored to its earlier rate and depth, or your chosen default."
- **Text:** `site/index.html:171` — "Hands your DAC back at the rate and depth it had before, when Vespertine quits."
- **Text:** `docs/ARCHITECTURE.md:13` — "`DeviceRestore` remembers each device's format before the first change, so it can be put back when Vespertine quits."
- **Property:** after quit, the device's nominal rate and physical format read back equal what they were before Vespertine first changed them (or the chosen default).
- **Governed by:** vespertine-rule.
- **Route:** hardware (`hardware/LOOPBACK.md`, step R2). `DeviceRestore` talks to Core Audio directly and has no seam that runs without a device.

### CL-RATE-04 <a id="rate-change-behind"></a>A rate change behind the engine's back is noticed

- **Text:** `docs/VERIFICATION.md:72` — "passes only if the song keeps its speed and the signal path names the rate the device really runs at"
- **Property:** after another program changes the device rate, the signal path shows the new rate and the verdict reflects it.
- **Governed by:** vespertine-rule.
- **Route:** hardware (existing opt-in `HardwareAuditTests`; `hardware/LOOPBACK.md`, step R1). The verdict group checks that a readback differing from the source rate removes the badge.

---

## Gapless, CUE, streaming and mute

### CL-GAP-01 <a id="gapless"></a>Gapless, including CUE albums

- **Text:** `docs/FEATURES.md:39` — "Tracks with the same output format play gaplessly, including CUE-sheet albums."
- **Text:** `site/index.html:170` — "Gapless, including CUE-sheet albums split from one file."
- **Text:** `docs/ARCHITECTURE.md:41` — "If the new plan is device-compatible (same rate, depth, mode and channels), decoding simply continues into the same ring buffer"
- **Property:** two consecutive device-compatible tracks (or CUE regions of one file) produce the same samples as the file played straight through, with no inserted or dropped frame at the boundary.
- **Governed by:** vespertine-rule. CUE sheets have no formal standard; the de facto reference is CDRWIN's documentation, and the index → frame mapping (75 frames per second) comes from the CD format (IEC 60908, paywalled).
- **Route:** inventory for this run: the boundary logic lives in `PlaybackEngine` and decoders and is not one of the seven groups the brief names. Hardware: the loopback hash comparison across a track boundary (`hardware/LOOPBACK.md`, step L3).

### CL-STREAM-01 <a id="stream-swap"></a>Swapping to the cached copy is sample-exact

- **Text:** `docs/VERIFICATION.md:62` — "switching from the network share to the cached copy mid-track doesn't drop or repeat a sample"
- **Governed by:** vespertine-rule.
- **Route:** inventory (existing `StreamingTests`).

### CL-MUTE-01 <a id="mute-no-skip"></a>Mute and rebuffering never skip music

- **Text:** `docs/VERIFICATION.md:63` — "mute and rebuffering never alter or skip music; they only insert silence where playback is actually held"
- **Property:** after a muted or held period, the next music sample out is the next one in the ring; nothing was consumed while held.
- **Governed by:** vespertine-rule.
- **Route:** spec-traced (DoP render group covers the DoP case; the PCM case uses the same render entry point and is covered by the float group's continuity requirement).

---

## Decoders

### CL-DEC-01 <a id="dec-lossless"></a>Lossless decoders are exact

- **Text:** `docs/ARCHITECTURE.md:58` — "A test checks TrueHD decodes identically to the 24-bit source it was encoded from."
- **Text:** `site/index.html:234` — "Lossless, can be bit-perfect"
- **Property:** decoding returns the encoder's input exactly.
- **Governed by:** oracle (the decoders are FFmpeg's and SFBAudioEngine's).
- **Route:** inventory.

---

## File analysis

### CL-HIRES-01 <a id="hires-padding"></a>Zero padding is detected exactly

- **Text:** `docs/FEATURES.md:53` — "Analysis detects zero-padded bit depth exactly."
- **Text:** `site/index.html:181` — "Only zero padding is exact"
- **Text:** `docs/ANALYSIS.md:13` — "Every sample's lowest bits are zero. Exact."
- **Property:** the reported effective bit depth is 24 minus the number of low bits that are zero in every sample.
- **Governed by:** vespertine-rule (a definition, not a standard).
- **Route:** inventory (`VespertineAnalysis` has its own tests; not one of the seven groups).

### CL-HIRES-02 <a id="hires-heuristics"></a>The other verdicts are estimates

- **Text:** `docs/FEATURES.md:53` — "Possible upsampling, lossy origin and synthetic high frequencies are spectral estimates, shown as questions with measurements and alternative explanations."
- **Text:** `docs/ANALYSIS.md:7` — "Only zero padding is exact."
- **Property:** none to test against a standard; the docs list the known false positives and misses (`docs/ANALYSIS.md#limits`).
- **Governed by:** heuristic.
- **Route:** inventory, by design.
