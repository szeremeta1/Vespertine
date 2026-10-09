# carrier-scan: final report

## Delivered
I delivered `/srv/cleanroom/carrier-scan/carrier_scan.py`. It is one Python 3 file that uses only the standard library and provides the `frames`, `scan` and `compare` commands. All 172 test checks pass. The DTS extension-substream path has only been tested on frames I generated myself.

- **AC-3:** I validate syncinfo and the whole bsi, including the Annex D syntax when bsid=6. Frame length comes from Table 5.18. Both CRCs are checked as A/52 7.10.1 describes: the register is zero at the 5/8 point (crc1) and zero again at the end of the frame (crc2), with the sync word left out.
- **E-AC-3:** I validate the bsi of Table E1.2 and check the single CRC over the frame, sync word left out. Independent, dependent and type-2 substreams are all treated as frames. A frame with bsid ≤ 8 is parsed as AC-3, one with bsid 11–16 as E-AC-3, and anything else is rejected.
- **DTS core:** I validate the bit stream header and the primary audio coding header (TS 102 114, 5.4.2 and 5.4.3). The length is FSIZE+1, which may be odd. An extension substream that follows a core is kept in the same frame when its header CRC (Annex B) checks.
- **Citations:** every field and constant in the code has a comment citing its clause or table.
- **Scanning:** the tool follows the brief. Candidates are 0x0B77 or 0x7FFE8001 at even offsets. After an accepted frame it continues at the next even offset. A sync word that does not make a valid frame adds one to `rejected_candidates`.

## What I tested it on
These scripts are in `dev/` and are not delivered. `dev/tests.py` holds the 172 checks; `dev/check_tables.py` cross-checks Table 5.18 against the spec text.

- **`frames` on the three samples:** 47 AC-3 frames and 47 E-AC-3 frames of 1536 bytes, and 92 DTS frames of 1024 bytes. Byte hashes are verified.
- **`frames` failure cases:** trailing bytes, a truncated last frame, a corrupted frame, leading junk and an empty file all exit 1. A stream mixing AC-3, E-AC-3 and DTS frames is accepted.
- **Carriers I built:** both byte orders; 1, 2 and 6 channels; extensible-format WAV, big-endian (RIFX) WAV and an odd-sized extra chunk; header words and zero padding between frames.
  - Tricky content: false sync words in the filler, sync words at odd offsets, a header word equal to 0x0B77, and frames shifted off word alignment.
  - Odd-length DTS frames, made by shortening each frame by one byte and patching FSIZE.
  - Damaged copies: one frame corrupted, a frame duplicated, two frames swapped, the last frame dropped, a carrier cut off mid-frame, and a carrier whose frames are split between the two byte orders.
  - A 60-second carrier with noise filler scans in about 0.5 s.
- **Reserved and invalid values:** I made frames with chosen header values and recomputed CRCs (including solving for crc1), then checked that each rule rejects what it should and accepts what it should.
- **Cross-checks:**
  - My Table 5.18 matches the spec text.
  - The 5/8 formula reproduces Table 7.34.
  - The CRC method passes on every frame of both samples.

## Ambiguities in the standards
1. **DTS Table 5-3:** the extracted table pairs FTYPE=1 with SHORT [0,30] and FTYPE=0 with 31, which contradicts "31 (indicating a normal frame)" and the 0x3f extended sync in 5.3. I used FTYPE=1 ⇒ SHORT=31 and FTYPE=0 ⇒ SHORT 0–30.
2. **DTS 5.4.3:** it says "nPCHS = PCHS+1 < 5", but a 5.1 core has 5 primary channels. I enforced nPCHS ≤ 5.
3. **DTS Table 5-17:** valid PCMR codes are listed as 0b110 and 0b101, where the pattern suggests 0b100. I followed the table as written, so 0b100 and 0b111 are invalid.
4. **DTS NBLKS:** "For normal frames … 4096, 2048, 1024, 512, or 256 samples" could be a description or a rule. I enforce it, so NBLKS ∈ {7, 15, 31, 63, 127} when FTYPE=1.
5. **DTS VERNUM 8–15:** these are called "incompatible … shall mute" rather than reserved. I reject them.
6. **DTS EXT_AUDIO_ID:** it only has meaning when EXT_AUDIO=1, so reserved codes are rejected only in that case.
7. **DTS core CRC:** there is no frame CRC. HCRC and AHCRC are present only when CPF=1, and the spec says "the CRC value test shall not be applied", so I only skip over them.
8. **DTS extension substream:**
   - Neither the brief ("without a core" is out of scope) nor 7.5.1 says how a core plus extension substream forms a frame. I report them as one frame, including 0–3 null alignment bytes.
   - Annex B gives only the polynomial and the starting value. I assumed MSB-first, no final XOR, and a compare against the stored value. This is untested on real data.
9. **E-AC-3 CRC coverage:** Annex E 3.2 says the CRC "covers the entire syncframe", while 7.10.1 says the sync word is not covered. I left the sync word out, which matches the sample.
10. **E-AC-3 mixdata length (mixdef=3):** Table E1.2 ("8*(mixdeflen+2) − no. mixdata bits" plus 0–7 fill bits) and E3.10.4 (the field includes mixdeflen) do not give one length. In that case I stop checking the bsi after the mixdata3e fields.
11. **Table E2.7:** premixcmpscl lists '000'–'101' and '111' but leaves out '110'. I treat '110' as invalid.
12. **Table 5.7:** bsmod=7 with acmod=0 is not listed. I reject it.

## Assumptions
- **What counts as a rejected value:**
  - "Header" means syncinfo plus bsi for AC-3 and E-AC-3, and the bit stream header plus primary audio coding header for DTS.
  - Any value the standard calls reserved, invalid, outside its valid range, or forbidden by a "shall" is rejected, even where decoders are told to fall back. That covers cmixlev, surmixlev, dsurmod and roomtyp =3, dialnorm=0, langcod≠0xFF, time codes out of range, Annex D dmixmod / Lt-Rt / Lo-Ro surround levels / dheadphonmod, xbsi2≠0, panmean ≥ 240, and the chanmap channel count.
  - An Annex D field is not checked for an acmod where the standard says its meaning is reserved.
  - **Risk:** this is strict. Older AC-3 streams that put real language codes in langcod would fail `frames`.
- **Elementary streams** are in the standards' big-endian byte order. A DTS file stored with byte-swapped 16-bit words is not accepted.
- **byte_order names:** `"big"` means the first byte of each pair is the sample's high byte. `"little"` means low byte first, which is the raw byte order of a normal WAV file.
- **When both byte orders find frames:** the tool picks the order with more frames, then more frame bytes, then fewer rejections, then "big". It also prints a warning on stderr.
- **What counts as a candidate:** only the core sync words. An extension-substream sync word is never a candidate and is not counted. A complete sync word whose frame runs past the end of the data counts as rejected.
- **`frames` output:** no `rejected_candidates` line. It prints the frames found before an error, then exits 1, and an empty file also exits 1.
- **`compare`:**
  - It uses the same byte-order choice as `scan` and compares codec, length and hash in order.
  - On success it prints one JSON summary and exits 0.
  - On mismatch it prints a JSON line with both frame counts, the missing, extra and reordered counts, and the first mismatch, then exits 1.
  - An invalid stream also exits 1, and rejected candidates do not affect the result.
- **WAV input:** RIFF or RIFX, PCM format tag 1 or the extensible format with a PCM subformat, 16 bits, block align = 2 × channels. A data size of 0 or one larger than the file means "read to the end of the file".
- **Exit codes and flags:** exit 2 is used for usage errors. An extra `-v` flag explains each rejection on stderr.
