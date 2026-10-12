# Brief: carrier scanner

You are writing a small, independent checking tool. Others work on related things separately; you will not see
their work. Your tool is judged by running it.

## Rules

- Work only in your workspace, `/srv/cleanroom/carrier-scan`. Do not read, list, search or open any path outside it (no `ls /`, no `find`
  outside the workspace, nothing under /home, /root, /tmp, /opt or /srv beyond your workspace), and don't try to
  find out what product or code this is for. Don't use the network, web search, GitHub or any tool other than
  these: Read, Write and Edit on files inside the workspace, and Bash only in exactly this form:
  `swiftbox /srv/cleanroom/carrier-scan "<command>"`. That runs `<command>` on Linux in a sandbox that sees only your workspace, mounted
  at `/work` (the command starts in `/work`). Python 3.12 is there as `python3`; use the standard library only.
- Your only sources are the two standards in `specs/` (one text file per PDF page, extracted with pdftotext) and
  the sample streams in `samples/`. Don't write the tool from memory of any other implementation; work from the
  standards, and cite the clause or table for every header field and constant in a code comment.
- Deliver `/srv/cleanroom/carrier-scan/carrier_scan.py`. Anything else you write (tests, generators) stays in your workspace and is not
  delivered.
- Finish with a short report as your final message: what you delivered, what you tested it on, everything in the
  standards you found ambiguous, and every assumption you made.

## Background

A player that can't decode Dolby Digital (AC-3), Dolby Digital Plus (E-AC-3) or DTS can still pass the compressed
frames to a receiver hidden inside a 16-bit stereo PCM signal. The frames' bytes ride in consecutive 16-bit PCM
samples, two bytes of the frame per sample, in sample order across both channels; between frames there are other
16-bit words (a few header words and zero padding). You are deliberately not told that container format and the
tool must not depend on it: it finds frames using only the codecs' own frame syntax. Which byte of each pair is the
high byte of the sample is not known, so the tool tries both orders.

The tool exists to show that every original frame arrives intact, in order, and that nothing else in the carrier
looks like a frame.

## The tool

`python3 carrier_scan.py frames <stream>`
: Split an elementary stream (a raw `.ac3`, `.ec3` or `.dts` file: frames back to back, nothing else) into frames.
  Print one JSON object per line: `{"offset": <byte offset>, "codec": "ac3" | "eac3" | "dts", "length": <bytes>,
  "sha256": "<hex of the frame's bytes>"}`. Exit 1 if the file isn't entirely valid frames back to back.

`python3 carrier_scan.py scan <carrier.wav>`
: Read a WAV file of 16-bit integer PCM (any channel count, normally 2). Turn its sample data into a byte stream,
  two bytes per sample in sample order, in each of the two byte orders, and scan each for frames. Print a first
  line `{"byte_order": ...}` naming the order that found frames, then one line per frame found, as above (offset
  = byte offset in that byte stream). Exit 1 if neither order finds a frame.

`python3 carrier_scan.py compare <carrier.wav> <stream>`
: Exit 0 exactly when the frames found in the carrier are the frames of the stream: the same bytes, in the same
  order, none missing, none extra. Otherwise print what differs (first mismatch, counts) and exit 1.

## Scanning rules

- A candidate frame starts at the codec's sync word, aligned to a 16-bit word of the carrier. Accept it only when
  its header is valid by the standard (reserved or forbidden values rejected), its length can be computed from the
  header, and the whole frame lies inside the data.
- For AC-3 and E-AC-3, also check the frame's CRC words exactly as A/52 defines them; a candidate that fails is
  not a frame. DTS core: check what TS 102 114 lets you check from the header (there is no mandatory frame CRC).
- After accepting a frame, continue after its last byte. Report, after the frames, one summary line
  `{"rejected_candidates": <n>}` counting sync words that didn't make a valid frame.
- Out of scope: DTS 14-bit packed streams, DTS extension substreams without a core, TrueHD, AAC. AC-3 and E-AC-3
  independent and dependent substreams are all frames.

## What you have

- `specs/atsc-a52-2018/page-NNN.txt`: ATSC A/52:2018, Digital Audio Compression (AC-3, E-AC-3) Standard.
- `specs/etsi-ts-102114-1.6.1/page-NNN.txt`: ETSI TS 102 114 V1.6.1, DTS Coherent Acoustics; Core and Extensions.
- `samples/sample.ac3`, `samples/sample.ec3`, `samples/sample.dts`: short elementary streams to test `frames` on.
  To test `scan` and `compare`, build your own carriers from them (any padding and filler you like, both byte
  orders, corrupted copies); the real container is not available to you.
