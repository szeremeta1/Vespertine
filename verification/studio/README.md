# Studio suite and evidence report

One command that tests Vespertine against the surround test pack on whatever Mac and audio hardware it finds, and writes
a report that keeps what was measured apart from what was not. Nothing here changes Vespertine itself; the suite checks
that the app, engine and library sources are the release's (`release code` line) and says so when they aren't.

    verification/studio/studio-suite.sh                      # from a Vespertine checkout
    STUDIO_LIBRARY=<pack folder> STUDIO_PYTHON=<python3 with numpy> verification/studio/studio-suite.sh --signal-path

Each run writes `results/<timestamp>/` (git-ignored; set `STUDIO_RESULTS` to put it elsewhere). `--help` lists the
options. Exit 0 means nothing failed; a SKIP is not a pass.

## What a run measures

| Step | What it does | Files |
| --- | --- | --- |
| swift test | the whole VespertineKit test suite (fixtures only, no hardware, no audio), under a time limit | `swift-test.log` |
| per-file captures | every pack file: size, SHA-256 against the pack's `SHA256SUMS.txt` / `MANIFEST.csv`; for audio files the raw `ffprobe` JSON, `afinfo` text and `vespertine-probe channels` line | `evidence/files.jsonl`, `evidence/sha256.txt`, `format-check.tsv` |
| source routing | `verify_chid.py` on every channel-ID, pink-walk and polarity file the pack's segments describe, decoded by FFmpeg and (where Core Audio opens the file) by Core Audio, compared with the pack's own recorded result | `evidence/chid-source.jsonl` |
| routing render | `StudioRoutingTests`: each of those files through Vespertine's own probe and decoder, written as a labelled CAF twice: the decoder's output, and converted the way the engine does for a discrete N-channel output with no speaker layout; `verify_chid.py --coreaudio` on each | `render/`, `evidence/render-check.jsonl` |
| device configuration | `StudioDeviceConfigTests`: per file, the plan the engine makes for the virtual device, the engine's own configuration step (exclusive access, rate, physical format), then Core Audio read back. No audio is played | `evidence/device-config*.jsonl` |
| signal path (`--signal-path`) | `vespertine-probe signal-path`: plays each file into the virtual device and compares the engine's live signal path with Core Audio | `evidence/signal-path*.jsonl` |
| captures (`--captures DIR...`) | re-runs `verify_chid.py` on `chid-capture.sh` runs, with a negative control (the capture with two channels swapped must fail) | `evidence/captures.jsonl` |
| report | `REPORT.md` and `evidence.json`; `results-sha256.txt` hashes every file in the folder | |

`REPORT.md` lists MEASURED claims first, each with its counts and the files that back it, then UNVERIFIED ones with the
reason. A measured failure stays MEASURED (result FAIL). Only state what a MEASURED line says, and name the machine,
macOS, release and device from its Environment section. Files from the pack's real-music and real-disc folders are not
named in `REPORT.md`.

## What it cannot measure, and what would

- **The engine's audio I/O on a loopback, from a process without Microphone permission.** A loopback such as Vespertine
  Loopback or BlackHole also has inputs, and Core Audio does not return from creating the engine's IOProc for such a
  process (over SSH, or under launchd): the engine waits inside `AudioDeviceCreateIOProcID`. `signal-path` reports this
  and stops (exit 4). Run the suite from Terminal.app with Microphone permission to measure it.
- **Multichannel routing to a device.** Needs a loopback with at least as many channels as the layout (BlackHole 16ch
  covers up to 7.1.4; 22.2 needs 24), or an interface's outputs looped back into its inputs. Then, from Terminal.app:
  `verification/studio/chid-capture.sh "09 5.1 side" <device UID> "<device name>"` per layout (UIDs from
  `vespertine-probe list`), and pass the run folders to `studio-suite.sh --captures`. A listening check on real speakers
  stays the primary proof.
- **DACs, receivers, bitstream, DoP.** Never automatic. Bitstream needs a receiver, a human present, low volume and
  `STUDIO_ALLOW_BITSTREAM="<exact device name>"`; DSD over DoP needs a DAC confirmed DoP-capable.

## Safety rules

The suite never plays a bitstream (AC-3, E-AC-3, TrueHD, DTS, IEC 61937) to any device, and plays nothing except into a
virtual device (`--loopback`, `--signal-path`; `signal-path` refuses anything else). The device configuration check
plays nothing. `chid-capture.sh` plays a PCM channel-ID file through the installed app with an isolated data dir and
launch arguments only; it refuses to start while that app instance is running rather than stop it.

## Tests

`python3 verification/studio/test_evidence.py` covers the parsers, the signal-path and configuration comparisons, the
segment resolver and the report's split (CI runs it on Linux).
