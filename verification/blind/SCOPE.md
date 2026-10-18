# Blind-agent round: source scope

Which behaviour of Vespertine's DoP and IEC 61937 output can rest on which public document, clause by clause, and
what can't be checked because the standard isn't public. The agents' copy of the scope (what they were told) is
[kit/SCOPE.md](kit/SCOPE.md); this file is the maintainer's map. Hashes of every file read are in
[corpus/sources.lock.json](corpus/sources.lock.json). Paid standards were not bought and nothing was pirated.

## DoP: fully public

| Behaviour | Source and clause | Tier |
|---|---|---|
| 24-bit PCM sample = 8-bit marker (MSBs) + 16 DSD bits; oldest bit in t0, right after the marker | DoP 1.1 §2, p.1-2 (figure "DSD Marker (8 MSbits) / 16 DSD Audio bits", "first or oldest bit in slot t0") | primary |
| Markers alternate 0x05 / 0xFA sample by sample; every channel of a frame carries the same marker | DoP 1.1 §2, p.2 | primary |
| One channel per PCM channel ("each PCM Frame contains only DSD data corresponding to its assigned channel") | DoP 1.1 §2, p.2 | primary |
| 64FS DSD on 176.4 kHz PCM; 128FS and up by raising the PCM rate, markers and bit order unchanged | DoP 1.1 §2 p.1, §3 item 1 p.2 | primary |
| Paired-channel 128FS method (markers 0x06 / 0xF9) | DoP 1.1 §3 item 2, p.2 | primary; **out of scope** (Vespertine doesn't use it) |
| Receiver switches after 32 consecutive markers / one missing marker | DoP 1.1 §4, p.3 | primary; receiver-side, out of scope |

Not settled by DoP 1.1 (gaps): which marker the first frame carries; what to send when there is no music (the
"DSD silence" idle pattern Vespertine sends); DoP in 32-bit containers (integer mode); byte order of the 24-bit
sample on the wire (a property of the PCM transport, not of DoP).

## IEC 61937: the normative text is not public

IEC 61937-1 (general: burst-preamble, burst-payload, stuffing), -2 (burst-info: data-type codes), -3 (AC-3,
E-AC-3) and -5 (DTS) are paid (CHF 160 + 90 + 90 + 100 at the IEC webstore). Only their free previews were read:
contents, foreword, scope, terms and definitions. So the round can't check any IEC 61937 clause directly. What it
can check, and from what:

| Behaviour | Public source | Tier |
|---|---|---|
| Burst = preamble Pa Pb Pc Pd + payload; Pa = 0xF872, Pb = 0x4E1F in 16-bit mode; Pa/Pb in frame k's two subframes, Pc/Pd in frame k+1's | SMPTE ST 337:2015 §7.2.1 Table 6, §7.2.2 (frame mode); applies to the consumer format per ST 337 §8.2 ("consumer bit stream format can, in general, be considered a subset") and §8.3 (16-bit frame mode for consumer compatibility) | sibling-standard |
| Pc layout in 16-bit mode: data_type bits 0-4, error_flag bit 7, data_type_dependent bits 8-12, stream number bits 13-15 | ST 337 §7.2.4.1 Table 7 | sibling-standard |
| Pd = payload length in **bits**, preamble not counted | ST 337 §7.2.5, Table 6 | sibling-standard (the consumer unit for E-AC-3 differs: see below) |
| Payload bits MSB-first from subframe 1's MSB; unused bits of the last frame 0; zeros between bursts | ST 337 §7.3.1 p.12; §6.1 p.6 ("Unused bit locations within a sub-frame or in subframes between bursts shall be set to '0'") | sibling-standard |
| Consumer data-type codes: AC-3 = 1, DTS type I/II/III = 11/12/13, E-AC-3 = 21 | ST 338:2016 §4 Table 1, column "IEC 61937-2 allocation (informative)" | sibling-standard (informative) |
| AC-3: one syncframe per burst, bursts 1536 frames apart, interface rate = audio rate | ST 340:2015 §4.3, §4.4, §4.6 (professional) and FFmpeg; 1536 samples per syncframe from A/52 §8.2.1.2. The round-2 auditor graded the professional clauses PARTIAL as consumer evidence (FFmpeg's `AC3_FRAME_SIZE` is defined in a header outside the corpus) | sibling-standard + secondary |
| AC-3 data_type_dependent = bsmod (consumer) | FFmpeg spdifenc.c only. ST 340 §4.2.2 gives the **professional** meaning (bits 0-2 reserved), which ST 337 §8.4 warns may differ from the consumer one | secondary |
| E-AC-3: data type 21, burst every 6144 frames at 4x the audio rate, Pd in **bytes** | ST 338 Table 1 (type 21, informative); repetition and unit: FFmpeg only. ST 340 §5 is the professional mapping (type 16, 1536 frames) and does **not** apply | sibling-standard (type) / secondary |
| E-AC-3: frames adding up to six audio blocks per burst | ST 340 §5.3 (professional) and FFmpeg | sibling-standard + secondary |
| DTS: type by frame length (512/1024/2048 samples), repetition = frame length, Pd in bits | ST 338 Table 1 (types, informative); period and unit FFmpeg only | sibling-standard / secondary |
| Frame headers used to build inputs and pick types (AC-3 syncinfo/bsi and Table 5.18 sizes, E-AC-3 bsi, DTS core header) | ATSC A/52:2018 §5.3-5.4, Annex E; ETSI TS 102 366; ETSI TS 102 114 §5.3-5.4 | codec-spec |

Not covered at all: IEC 60958 channel status (Vespertine sets none), pause bursts, burst spacing rules of
IEC 61937-1, E-AC-3 and DTS rules that only IEC 61937-3/-5 state (e.g. latency, reference point), DTS-HD,
TrueHD/MAT, 20/24-bit modes, multiple streams.

What a pass on a `secondary` row means: Vespertine agrees with an independent implementation (FFmpeg) as read by
a blind agent, not that it conforms to IEC 61937. Buying IEC 61937-1/-2/-3/-5 (CHF 440) would turn those rows
into primary ones.
