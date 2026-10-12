# DST fixtures

Fifteen DST frames (DSD64, 1/75 s each) and the DSD each one encodes:

| Frames | Channels | Coding |
|---|---|---|
| `2ch-v0` … `2ch-v5` | 2 | DST, encoder variants 0–5 |
| `5ch-v0` … `5ch-v2` | 5 | DST, variants 0–2 (the last two channels share a filter and table) |
| `6ch-v0` … `6ch-v2` | 6 | DST, variants 0–2 |
| `2ch-stored`, `5ch-stored`, `6ch-stored` | 2, 5, 6 | stored uncompressed |

`<name>.dst` is the frame, `<name>.dsd` the expected output: `channels × 4704` bytes, channel bytes interleaved in channel order, most significant bit oldest. `fixtures.json` lists them.

**Where they come from.** `tools/dst-fixtures/build.sh` runs the small DST encoder in Vespertine's own test support (`Packages/VespertineKit/Tests/VespertineTestSupport/SACDFixture.swift`) over a sigma-delta tone per channel. Its variants switch between plain and Rice-coded filters and tables, filter lengths, probability tables and half probability. The expected DSD is the encoder's input.

**Why they can be trusted.** On its own that would be circular: Vespertine's tests wrote the encoder. So `oracles/dst/check_fixtures.py` decodes every frame with the MPEG-4 Audio reference decoder (libdstdec, at the commit pinned in record DST-003) and requires the same bytes. CI runs it on every change; it passed for all fifteen when they were written. A fixture that libdstdec doesn't decode to its `.dsd` is not a valid expected answer.

**What they don't cover.** Only the coding tools this encoder uses. Real discs use the same decoder paths in other combinations; `hardware/SACD-ORACLE.md` compares Vespertine with sacd_extract on real images. Which frames the standard calls invalid is in ISO/IEC 14496-3, which isn't in hand (DST-005), so there are no damaged-frame fixtures.
