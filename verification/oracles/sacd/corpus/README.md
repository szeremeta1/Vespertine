# Real SACD corpus audit

The synthetic SACD tests exercise plain/raw sectors, stereo/surround, plain DSD and DST,
redundant TOCs, damage concealment, track boundaries, seeking, PCM and DoP. The opt-in
real-disc test adds full-frame reading of an actual image and probes the beginning,
middle and end of every track through the app's `SourceOpener`, PCM and DoP decoders.
It does not open an output device or change the source file.

```sh
cd Packages/VespertineKit
VESPERTINE_SACD_AUDIT_IMAGE=/path/disc.iso \
VESPERTINE_SACD_AUDIT_OUTPUT=/tmp/disc-audit.json \
swift test --filter realSACDCorpusImage
```

For a large collection stored on Linux, avoid transferring every image to a Mac:

```sh
python3 verification/oracles/sacd/corpus/build_core.py /tmp/sacd-core
python3 verification/oracles/sacd/corpus/audit.py \
  /tmp/sacd-core/sacd-core /private/image-paths.json /private/corpus.jsonl
```

Requires Swift 6.2 or later, Clang and Python 3. The path list is a JSON array of
absolute image or compressed DSDIFF paths. Add `--jobs 4` for a bounded parallel pass. The report appends one record per image. All DSD is streamed
through SHA-256; no audio is saved. Nonzero concealed-frame counts fail the image.
Each track has its own hash, plus a hash for its whole stereo or surround area.
The original file's size and modification time must remain unchanged.

The portable runner copies the **production** DSDIFF container reader, SACD TOC parser, frame reader, seeking,
DSD source and DST C implementation. Only macOS imports, the `RawDSDSource` protocol
conformance and the unused `InputSource` property are omitted. Linux gets an identity
localization initializer. Source hashes record precisely what was built. This
checks the real extraction core, but does not stand in for macOS PCM/DoP integration;
run the native test above on representative images too.

Compare canonical interleaved, MSB-first DSD hashes with independent `sacd_extract`
output. `../compare_dsd.py` documents DSDIFF/DSF layout conversion. Track boundaries
may include pauses differently; a length discrepancy must be investigated and
recorded rather than reported as an identical track. Keep private source paths and
audio outside the repository; commit only sanitized results.
