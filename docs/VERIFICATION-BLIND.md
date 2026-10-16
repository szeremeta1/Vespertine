# Blind-agent verification of DoP and IEC 61937 output

This page covers a check of Vespertine's DSD-over-PCM (DoP) output and its IEC 61937 bitstream bursts (Dolby
Digital, Dolby Digital Plus and DTS over S/PDIF or HDMI). The tests were written by agents that never saw
Vespertine's code. They worked only from the published standards. Deliberately broken implementations then
proved the tests can fail.

The method copies the one anotherhobby described for audio-vue in ASR thread 73834
(<https://www.audiosciencereview.com/forum/index.php?threads/73834/>, posts #2 and #4). It was run on
2026-10-16. Everything it produced is in [`verification/blind/`](../verification/blind/). Nothing in the app was
changed. This is separate from, and doesn't replace, the spec-traced harness in
[`verification/`](../verification/README.md).

**Result in one paragraph.**
- On valid input, Vespertine's bytes are what the public sources call for, as far as those sources go.
  - 28 of 30 fixed inputs came out byte-identical to two independently written blind reference implementations.
  - The blind suite has 276 cases, and none of its assertions about output values failed against Vespertine.
- Ten cases failed. Each one asks the framer to refuse bad input, and Vespertine's framers never refuse anything.
- The two inputs that didn't match exposed a real but hard-to-reach flaw: a payload too big for its burst is cut
  short, while the length word still claims the full size.
- The paid IEC 61937 standard wasn't available, so for IEC 61937 this shows agreement with SMPTE's public
  professional sibling standard and with FFmpeg. It does not show conformance to IEC 61937 itself.

## Method

### 1. Corpus: public sources only

| doc-id | Document | Tier |
|---|---|---|
| `dop-1.1` | DoP open Standard v1.1 (dsd-guide.com) | primary |
| `iec61937-1/-2/-3/-5-preview` | The IEC webstore's free previews: contents, foreword, scope, terms | primary-preview |
| `smpte-st337-2015`, `smpte-st338-2016`, `smpte-st340-2015` | SMPTE's free professional (AES3) counterpart: burst format, data types, AC-3/E-AC-3 | sibling-standard |
| `atsc-a52-2018`, `etsi-ts-102366`, `etsi-ts-102114` | AC-3/E-AC-3 and DTS bitstream syntax (frame headers, sizes) | codec-spec |
| `ffmpeg-spdif-n7.1` | FFmpeg's S/PDIF muxer source, `spdifenc.c` and `spdif.h` | **secondary**: an implementation, not a specification |

IEC 61937 itself is paid and was not bought (see [`verification/SOURCES.md`](../verification/SOURCES.md) for
prices). Nothing was pirated. URLs and SHA-256 hashes of every file are in
[`verification/blind/corpus/sources.lock.json`](../verification/blind/corpus/sources.lock.json). The text
itself isn't committed; `tools/fetch_corpus.py` downloads it again and refuses any file whose hash differs.
[`verification/blind/SCOPE.md`](../verification/blind/SCOPE.md) maps each behaviour to the clause it rests on,
and lists what no public source covers.

### 2. A deterministic normalizer

`tools/normalize.py` turns every PDF into markdown, one fenced `pdftotext -layout` block per page, so tables
keep their columns. Each page gets an anchor (`[doc p.N]`) and each detected heading a section anchor
(`[doc §7.2.5 p.12]`). Running it again on the same inputs gave byte-identical files. The ST 337 tables
(Table 6 preamble words, Table 7 burst_info bits) and the A/52 frame-size table were checked by eye.

### 3. Isolated rooms, blind roles

Each role ran headless in its own directory, through Vesper's `vesper-run --kind code-small --write
--tools Read,Grep,Glob` (no web tools). It got only the files its manifest names (`tools/make_room.py`):
- the corpus;
- the agent-facing [scope](../verification/blind/kit/SCOPE.md) and [rulings](../verification/blind/kit/RULINGS.md);
- a hand-written [interface stub](../verification/blind/kit/stub/vblind.py), which states representations
  but no spec values;
- for test-running roles, the pytest harness and the [citation checker](../verification/blind/kit/harness/citecheck.py).

No role had repository access. Every tool call was traced (Vesper's delegated-command log) and checked by
`tools/isolation.py`. Each room's file list with hashes is in `rounds/*/*/ROOM-MANIFEST.txt`, and its trace
check in `rounds/*/*/ISOLATION.txt`.

| Role | What it did | Model |
|---|---|---|
| meter | Reference DoP packer/unpacker and IEC 61937 framer/parser from the corpus text, every constant cited | Claude Sonnet 5.5 (r1), GPT-6.1 Sol (r2 fix) |
| tester | pytest suite against the stub. Every `assert` carries `[KEY]` citations (doc, section, page, verbatim quote, tier); tests that rest only on FFmpeg are marked `secondary` | Claude Sonnet 5.5 (r1), GPT-6.1 Sol (r2 fix) |
| saboteur | Its own correct implementation (`base.py`) and 6 variants, each breaking exactly one cited behaviour | GPT-6.1 Sol |
| auditor | Ran the suite against everything, then graded every citation against its page; verdict on line 1 | GPT-6.1 Sol |

The brief asked for the Max account for every role. `vesper-run`'s router sends work elsewhere when Max's
5-hour window runs hot (it was at 81%), so five of the seven runs went to Codex.

Isolation results:
- Every trace was checked. 175 tool calls stayed inside their rooms, and none used the network or git.
- Two flags in the round-1 tester's trace were checked by hand. One was a `cd ..` from `corpus/md` back to the
  room; the other was Python's `open()`.
- The round-1 tester disclosed one slip itself: `cat > /tmp/x` created an empty file outside its room.

### 4. Two rounds, as in the original

**Round 1** ended with **VERDICT: FAIL**. The meter failed 2 of 159 cases because it refused odd-length DTS
frames, which no source forbids. One citation (`ST340_AC3_DTD_RESERVED`) passed off a professional-only rule
as a consumer one. Several tiers were overstated.

Each builder then got only the auditor's verbatim findings about its own work
([`kit/excerpts/`](../verification/blind/kit/excerpts/)):
- The meter was rebuilt: odd DTS frames are now padded, and its citations were corrected.
- The tester fixed every finding. It removed the bad key, marked 26 more test functions `secondary` (8 before,
  34 after), and added all 114 AC-3 frame-size cases and 3 parser cases.

**Round 2** used a fresh auditor and ended with **VERDICT: PASS WITH FINDINGS**.

### 5. Bridge to Vespertine

`verification/blind/bridge/` is a small Swift package that depends on VespertineKit read-only. It runs
Vespertine's own code:
- `RawDoPDecoder`, the DoP packer behind DSF, DSDIFF, SACD and DST playback;
- `IEC61937.ac3Burst`, `eac3Burst` and `dtsBurst`, and the E-AC-3 grouper;
- `BitstreamDecoder` over real `.ac3` and `.ec3` files (the playback path).

It runs them in two ways:
- **Export:** on the 30 fixed inputs in `vectors/inputs.json` (`tools/vectors.py`, headers built from A/52 and
  TS 102 114), compared byte for byte by `tools/compare.py`. Bursts are compared as interleaved s16le, DoP as
  interleaved s24le.
- **Serve:** behind the blind interface (`tools/vespertine_adapter.py`), so the tester's suite runs against
  Vespertine itself. Vespertine has no DoP unpacker or burst parser, so tests of those are reported as not
  applicable. The "+ reference parser" row reads Vespertine's output with the blind meter's parser instead.

## Results

### The suite and the saboteurs

| Implementation | Round 1 (159 cases) | Round 2 (276 cases) |
|---|---|---|
| bare stub | 0 pass / 159 fail | 0 / 276 |
| meter (blind reference) | 157 / 2 | **276 / 0** |
| saboteur base (second blind reference) | 159 / 0 | **276 / 0** |
| `sab_swapped_markers` (DoP 0x05/0xFA exchanged) | caught by 7 | caught by 7 |
| `sab_dop_bit_order` (16 DSD bits reversed) | caught by 6 | caught by 6 |
| `sab_pc_datatype` (DTS type III announced as II) | caught by 1 | caught by 1 |
| `sab_length_off_by_one` (E-AC-3 Pd + 1) | caught by 4 | caught by 4 |
| `sab_padding` (stuffing words 0x0001) | caught by 11 | caught by 11 |
| `sab_byte_order` (payload bytes swapped in each word) | caught by 23 | caught by 137 |
| Citations | 88, all resolve; auditor: 69 SUPPORTS, 18 PARTIAL, 1 DOES-NOT-SUPPORT | 93, all resolve; 81 SUPPORTS, 12 PARTIAL, 0 DOES-NOT-SUPPORT |
| Auditor verdict | FAIL | PASS WITH FINDINGS |

Full tables are in `rounds/r{1,2}/results/matrix.md`, the audits in `rounds/r{1,2}/auditor/AUDIT.md`, and the
suite's requirement map with its gaps in `rounds/r2/tester/tests/REPORT.md`.

The pc-datatype saboteur is caught by a single case, so that margin is thin. The remaining PARTIAL grades
mostly mean "professional clause used as structural evidence for the consumer format" or "quote shorter than
the row it relies on". All are disclosed.

### Vespertine against the blind suite (round 2)

| | passed | failed | not applicable |
|---|---|---|---|
| Vespertine | 229 | 10 | 37 |
| Vespertine + reference parser | 259 | 10 | 7 |
| of which: cases resting on public standards (not `secondary`) | 76 | 5 | 25 |
| of which: cases resting on FFmpeg only (`secondary`) | 153 | 5 | 12 |

Every one of the 10 failures is a refusal Vespertine doesn't make (`DID NOT RAISE`):

| Test | Reachable in playback? |
|---|---|
| `test_pack_rejects_odd_byte_count` (DoP) | `RawDoPDecoder` drops a trailing odd byte per channel (`FFmpegDecoder.swift:233`). DoP 1.1 doesn't say what to do with half a frame; at most 8 DSD bits at the end of a track. |
| `test_ac3_rejects_wrong_syncword`, `test_ac3_rejects_truncated_syncframe`, `test_eac3_rejects_wrong_syncword` | Not from `.ac3`/`.ec3` files: `DolbyFrames.frame(in:at:)` (`Bitstream.swift:106-107`) checks the sync word and the full size first. From MP4, yes: a sample that doesn't parse is still framed (`Bitstream.swift:305-306`). |
| `test_eac3_rejects_partial_group` | Yes, once per stream: the grouper's `finish()` (`Bitstream.swift:169`) sends whatever is left as a short last burst. |
| `test_eac3_rejects_more_than_six_blocks` | Not with real streams: block counts are 1, 2, 3 or 6 and stay constant. |
| `test_dts_rejects_*` (4 cases) | No: `IEC61937.dtsBurst` is never called in playback (finding F-02 in `verification/FINDINGS.md`). |

### Vespertine against the blind references, byte for byte (round 2 meter)

| Inputs | Result |
|---|---|
| DoP: 6 inputs (both start markers, mono bit-order probe, 6 channels, 8192 bytes × 2 crossing buffer boundaries, 0x69 pattern) | 6/6 identical |
| AC-3 bursts: 5 frames (48/44.1/32 kHz, 32-640 kbit/s, bsmod 0/1/2/4/7) | 5/5 identical |
| E-AC-3 bursts: 6 groups (1×6, 2×3, 6×1 blocks, independent+dependent, 4096-byte frame) | 5/6 identical; 1 refused by the reference (below) |
| DTS bursts: 6 frames (512/1024/2048 samples, odd length, exact fit) | 5/6 identical; 1 refused (below) |
| E-AC-3 grouping: 4 frame sequences | 4/4 same groups |
| `BitstreamDecoder` end to end: one `.ac3` file (5 frames), two `.ec3` files (3-block ×8; independent+dependent ×4) | 3/3 identical carriers (30 720, 98 304, 98 304 bytes) |

The saboteur's independent `base.py` gives the same 28/30 and refuses the same two inputs
(`rounds/r*/results/compare-base.md`).

## Findings

| ID | What | Exact evidence | Reach | Severity |
|---|---|---|---|---|
| B-01 | A payload bigger than its burst is cut short, but Pd still gives the full length (`IEC61937.burst`, `Bitstream.swift:47-58`) | E-AC-3, 6 × 4096-byte frames (24 576 bytes): Pd = 0x6000 (24 576 bytes), but only 24 568 fit after the preamble. Stream bytes 24 568-24 575 are dropped, so Pd points 8 bytes (4 words) past the end of the burst, into the next burst's preamble. DTS, 2044-byte 512-sample frame: Pd = 0x3FE0 (16 352 bits), 2040 bytes carried, 4 dropped. | E-AC-3 only at the format's ceiling (6.144 Mbit/s); DTS path dormant | low |
| B-02 | The last E-AC-3 burst of a stream can carry fewer than six audio blocks | `EAC3Grouper.finish()`; blind test `test_eac3_rejects_partial_group` (secondary tier). Only the professional ST 340 §5.3 states the six-block rule; the consumer rule isn't public. | once per stream, at the end | low |
| B-03 | The burst framers don't validate their input; validation sits upstream | MP4 samples that fail `DolbyFrames.frame` are forwarded with `blocks: 6` (`Bitstream.swift:305-306`) | damaged MP4 files | low |
| B-04 | An odd trailing DSD byte per channel is dropped | `FFmpegDecoder.swift:233` | at most 8 DSD bits at a track's end; DoP 1.1 is silent | info |

These are observations for the maintainer. How to handle them (refuse, split, skip or pad) is a design choice.

## What this does not cover

- **Conformance to IEC 61937** itself. Its clauses on the preamble, data types, stuffing, repetition periods and
  the AC-3/E-AC-3/DTS mappings are paid. Every IEC 61937 pass here means agreement with ST 337/338/340 (the
  professional sibling) and with FFmpeg as read by a blind agent. Rows marked secondary rest on FFmpeg alone.
  Buying IEC 61937-1/-2/-3/-5 (CHF 440) would let a round test against the standard.
- The consumer `data_type_dependent` fields. AC-3 bsmod in Pc bits 8-10 rests on FFmpeg only; E-AC-3 and DTS
  use zero.
- Pd for odd-length DTS payloads: exact bits (what Vespertine and both blind references send) or rounded up to a
  whole word (FFmpeg's generic path). This is untested.
- E-AC-3 with several independent substreams, and the convsync alignment rule.
- DoP behaviour the standard doesn't define: the start marker, the idle "DSD silence" frames sent by
  `vespertine_rt.c` (not bridged), and 32-bit integer containers. The paired-channel 128FS method isn't used by
  Vespertine.
- SFBAudioEngine's own `DoPDecoder`, which is only a fallback for DSD extensions FFmpeg doesn't open. It isn't
  bridged.
- Channel status, receivers and real hardware. The inputs are synthetic frames with valid headers, not decodable
  audio.

## Running it again

```sh
python3 -I verification/blind/tools/fetch_corpus.py                 # corpus from the pinned URLs, then normalize
python3 -I verification/blind/tools/vectors.py verification/blind/vectors
(cd verification/blind/bridge && BLIND_VECTORS=$PWD/../vectors swift test)   # Vespertine's output -> vespertine.json
python3 -I verification/blind/tools/compare.py verification/blind/vectors verification/blind/rounds/r2/meter/vblind_ref.py
python3 -I verification/blind/tools/run_matrix.py verification/blind/rounds/r2 <python with pytest> --vespertine
```

A new round starts from `tools/make_room.py <role> <rooms_dir>` and the briefs in `verification/blind/kit/briefs/`.
