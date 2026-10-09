# Contributing to Vespertine

Thanks for helping. Vespertine is a one-maintainer project, so the most useful things you can send are clear reports from real hardware and small, focused pull requests.

## Release cadence

Betas ship at most weekly; the 1.0 freeze starts November 3, 2026.

## Reports

- **Something broke:** [open a bug report](https://github.com/szeremeta1/Vespertine/issues/new?template=bug_report.yml). Include the Vespertine version (Vespertine › About Vespertine), your macOS version and Mac, the output device, and what the signal path said.
- **Your DAC, receiver or interface, working or not:** [open a device report](https://github.com/szeremeta1/Vespertine/issues/new?template=dac_report.yml). Multichannel DAC output and receiver bitstream are experimental, untested on real receivers/multichannel DACs; reports wanted. Intel Macs and DSD DACs other than the FiiO K11 are also untested. [docs/VERIFICATION.md](docs/VERIFICATION.md) explains how to check bit-perfect playback yourself.
- **An idea or a question:** start a [discussion](https://github.com/szeremeta1/Vespertine/discussions) first, so we can agree on the shape of it before anyone writes code.
- **A security problem:** report it privately, as [SECURITY.md](SECURITY.md) describes, not in a public issue.

A file that won't play is most useful with the file itself, or a short excerpt of it, and the output of `ffprobe` on it.

## Building

You need a Mac with Xcode and XcodeGen (`brew install xcodegen`). Vespertine runs on macOS 14.4 and later.

```bash
scripts/generate-project.sh && open Vespertine.xcodeproj
```

The README's [Build](README.md#build) and [Try it without your own music](README.md#try-it-without-your-own-music) sections cover command-line builds, the test suites, a synthesized demo library and the command-line tools that drive the real engine.

## Pull requests

- Keep each pull request to one change, and say in the description what a listener would notice before and after.
- Run the tests for what you touched before opening it: `swift test` in `Packages/VespertineKit` and `Packages/VespertineAnalysis`, or `scripts/audit.sh` for everything, including the app tests and sanitizer builds of the real-time code.
- Nothing on the audio thread may allocate, lock or call into Objective-C. If you change code in `CVespertineRT` or the render path, say how you checked that.
- Never weaken the bit-perfect check. Anything that changes the samples must show up in the signal path and turn BIT-PERFECT off.
- Match the surrounding code: its naming, its comment density, and plain user-facing text that says what happened rather than what might have.
- `project.yml` is the source of truth for the Xcode project; edit it rather than the generated `.xcodeproj`.

CI runs the analysis tests on Linux for every pull request, and the macOS engine and app builds once it is ready for review.

## License

Vespertine is GPL-3.0-or-later. By sending a pull request, you agree that your contribution is licensed the same way. Third-party code needs a compatible license and an entry in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

Please follow the [code of conduct](CODE_OF_CONDUCT.md).
