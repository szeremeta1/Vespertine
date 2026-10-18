# COMPLIANCE: meter/vblind_ref.py

Quotes are given in the source comments next to each constant. Tier = best tier among the citations (RULINGS R2).

| Requirement implemented | Citation (doc §section p.) | Tier |
|---|---|---|
| DoP word = 24-bit: 8 MSb marker, 16 DSD bits, oldest bit first (byte 0 high) | dop-1.1 §2 p.1-2 "first or oldest bit in slot t0" | primary |
| Marker alternates 0x05 / 0xFA each sample | dop-1.1 §2 p.2 "alternate with each sample between 0x05 and 0xFA" | primary |
| Same marker on every channel of a frame | dop-1.1 §2 p.2 "Each channel within a sample contains the same marker" | primary |
| One PCM frame = one DoP word per DSD channel; higher DSD rate = higher PCM rate only | dop-1.1 §3 p.2 solution 1 "All the marker bytes and bit ordering remain the same" | primary |
| 0x06/0xF9 refused (other method) | dop-1.1 §3 p.2 "A different marker byte is used" | primary |
| Odd byte count refused (16 bits per slot) | dop-1.1 §2 p.2 | primary (reading) |
| Burst sync Pa=0xF872, Pb=0x4E1F (16-bit) | smpte-st337-2015 §7.2.1 p.9 Table 6; §8.2 p.14; ffmpeg spdif.h | sibling-standard (+secondary) |
| Pa/Pb in Ch1/Ch2 of first frame, Pc/Pd next frame (even word index) | smpte-st337-2015 §7.2.2 p.9 | sibling-standard |
| Pc layout: type 0-4, mode 5-6, error 7, dtd 8-12, stream 13-15 | smpte-st337-2015 §7.2.4.1 p.10 Table 7 | sibling-standard |
| 16-bit frame mode only, stream 0 | smpte-st337-2015 §8.3 p.14 | sibling-standard (informative) |
| Payload packed MSB-first into subframe 1 then 2; unused bits zero; lone byte MSB-aligned | smpte-st337-2015 §7.3.1 p.12; ffmpeg spdifenc | sibling-standard |
| length_code <= 65535 in 16-bit mode | smpte-st337-2015 §7.2.5 p.12 | sibling-standard |
| length unit bits for AC-3 and DTS | smpte-st337-2015 §7.2.5 p.12; ffmpeg spdifenc | sibling + secondary |
| length unit BYTES for E-AC-3 | ffmpeg spdifenc `length_code = hd_buf_filled` | **secondary** |
| data_type 1 AC-3; 11/12/13 DTS I/II/III; 21 E-AC-3 | smpte-st338-2016 §4 p.4-5 Table 1 IEC column; iec61937-3-preview contents "data-type bits 0-4 = 21"; ffmpeg spdif.h | sibling (informative IEC column) + preview + secondary |
| AC-3 dtd = bsmod (bits 0-2) | ffmpeg spdifenc `IEC61937_AC3 \| (bitstream_mode << 8)` | **secondary** |
| AC-3 period 1536 frames; payload = one whole sync frame | smpte-st340-2015 §4.3 p.5, §4.6 p.6; ffmpeg | sibling + secondary |
| AC-3 frame size / sync / bsid<=8 / bsmod position | atsc-a52-2018 §5.3.1 p.31, §5.4.1 p.20, Table 5.18 p.52-53, §5.4.2.1-2 p.39 | codec-spec |
| E-AC-3 frame header (strmtyp, substreamid, frmsiz, fscod, numblkscod, bsid) and size | etsi-ts-102366 §E.1.2.2 p.114, §E.1.3.1 p.127; atsc-a52-2018 Annex E p.161 | codec-spec |
| E-AC-3 burst payload = frames giving six blocks, first frame independent substream 0 | smpte-st340-2015 §5.3 p.9-10; etsi-ts-102366 §J.1.4.1 p.241 | sibling + codec-spec |
| E-AC-3 period 6144 frames (not ST 340's 1536) | ffmpeg spdifenc `pkt_offset = 24576` | **secondary** |
| DTS core header: sync 0x7FFE8001, NBLKS (5..127), FSIZE (95..16383, size = FSIZE+1), samples = 32(NBLKS+1) | etsi-ts-102114 §5.4.2 p.25 Table 5-1 | codec-spec |
| DTS period = samples per frame (512/1024/2048 frames); truncation to FSIZE+1; refusal when it cannot fit | ffmpeg spdifenc `pkt_offset = blocks << 7`, "bitrate is too high" | **secondary** |
| Fill after payload is zero up to the repetition period | smpte-st340-2015 §4.1 p.4 "padding"; smpte-st337-2015 §7.4 p.13 | sibling-standard |
| parse_bursts: error_flag/stream/dtd/data_type decoded; data_mode!=0 and type 31 refused | smpte-st337-2015 §7.2.4 p.10-11, §7.2.1 p.9 | sibling-standard |

## Not settled (full list with the choice made is in the module docstring: O1-O14, G1-G6)
* No normative IEC 61937-1/-2/-3/-5 text: consumer sync words, data-type numbers, length unit, periods are not
  confirmed by a consumer primary source (G1).
* Consumer data_type_dependent for AC-3 (bsmod in 0-2? ST 340 says 000 for professional), E-AC-3 and DTS (G2).
* E-AC-3 length unit (bytes) and period (6144 frames) rest on FFmpeg only (G3); ST 340 (professional) says bits/1536.
* convsync check on the first E-AC-3 frame not done (G4). Reduced-rate E-AC-3 periods (G5).
* DTS: behaviour for odd sizes, exact-fit (preamble-less) frames, and oversize frames is FFmpeg-derived or a choice (O9).
* DoP: silent on empty streams, odd byte counts, and whether a receiver needs 32 markers before accepting (O1-O3).
