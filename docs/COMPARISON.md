# Comparison sources and scope

The [README table](../README.md#compared-with-other-mac-players) and [website table](../site/index.html#compare) cover the same features. `?` means unverified. It is not a claim that a player lacks the feature. No prices or overall sound-quality rankings are included. Corrections welcome through [GitHub issues](https://github.com/szeremeta1/Vespertine/issues).

The starting point was the maintainer's October 9, 2026 competitor-review summary. The feature rows follow that review: file formats, output control, local surround, Spatial Audio, analysis, source availability, SACD ISO, convolution/plugins and streaming services. The primary pages below were checked for this documentation update. A documented feature is not a Vespertine hardware test of a competitor.

## Vespertine

The [feature details](FEATURES.md), [signal-path conditions](../Packages/VespertineKit/Sources/VespertineAudio/SignalPath.swift) and [verification guide](VERIFICATION.md) describe what the app implements and how it is checked. The table says “conditions + tests” rather than claiming an independent loopback result.

Receiver bitstream and multichannel DAC output are experimental, untested on real receivers/multichannel DACs; reports wanted. Decoding, routing and carrier tests do not establish hardware compatibility. SACD ISO playback is new (two real discs tested against sacd_extract). There is no convolution, audio effect plugin hosting or streaming-service integration.

## Apple Music on Mac

The supplied October 2026 review reports third-party Nativerate loopback tests on an RME interface: bit-exact 16/24-bit PCM from 44.1 to 192 kHz on macOS 27.0.1, at 100% player volume. It also reports no automatic DAC rate switching, no hog mode, no FLAC/DSD, and a failed 32-bit test. The original third-party test report could not be independently rechecked for this update. The table attributes the 16/24-bit result to those tests and makes no claim about other configurations.

[Apple's lossless-audio support page](https://support.apple.com/en-us/118295) documents ALAC playback and manual selection of the Mac's output rate in Audio MIDI Setup. It is not the source of the macOS 27 bit-exact measurement. Unchecked local-surround and Spatial Audio cases remain `?`.

## Audirvana Studio and Origin

[Origin's product page](https://audirvana.com/audirvana-origin/) documents local FLAC and DSD, a one-time purchase without streaming services, and optional convolution. The supplied review covers native-rate/exclusive output and multichannel playback. [Audirvana's product page](https://audirvana.com/) distinguishes Studio's streaming integration from Origin's local library. [Audirvana's history](https://audirvana.com/about/) records AudioScan as a feature; hi-res analysis is not exclusive to Vespertine.

Plugin hosting is not independently rechecked here, so it remains `?`. SACD ISO and local Apple Spatial Audio also remain `?`; these are not inferred from the Windows edition or a forum post.

## Roon

[Roon's audio setup guide](https://help.roonlabs.com/portal/en/kb/articles/audio-setup-basics) documents exclusive mode, DSD strategies and output controls. [Multichannel](https://help.roonlabs.com/portal/en/kb/articles/multichannel) documents local files with up to eight channels. [Convolution](https://help.roonlabs.com/portal/en/kb/articles/dsp-engine-convolution) documents filters. FLAC, rate switching and streaming-service integration are included in the supplied comparison review. Plugin hosting, SACD ISO, analysis and local Apple Spatial Audio remain `?`.

## VeraVox

[VeraVox's FAQ](https://www.veravox.audio/faq.html) documents FLAC, DSD, SACD ISO, exclusive output and hi-res analysis. Its [technical documentation](https://www.veravox.audio/technical.html) and [exclusive-mode guide](https://www.veravox.audio/exclusive-mode-macos.html) describe the in-app bit-perfect loopback test. These are documented capabilities, not measurements made for this update. VeraVox is proprietary according to the supplied review and its [license](https://www.veravox.audio/eula.html).

## Swinsian

[Swinsian's site](https://swinsian.com/) was unavailable to the documentation check because its robots policy blocked retrieval. The supplied review summary does not establish its individual features. Its cells remain `?` rather than guessing from older comparisons.

## Colibri

[Colibri's product page](https://colibri-lossless.com/) lists FLAC and DSD. Its [FAQ](https://colibri-lossless.com/faq/) confirms automatic rate switching and says SACD ISO is unsupported. Its [change log](https://colibri-lossless.com/changes/) documents exclusive/hog mode. Unchecked capabilities remain `?`.

## Cog

[Cog's site](https://cog.losno.co/) describes a free, open-source player and lists FLAC, DSD, DTS, TrueHD and head tracking. Its October 4, 2026 release notes document surround spatialization with Apple's renderer. The table therefore includes local surround and Apple Spatial Audio. Vespertine does not claim to be the only player offering them.

## foobar2000 for Mac

The [Mac download page](https://www.foobar2000.org/mac) and [Mac change log](https://www.foobar2000.org/changelog-mac) identify the Mac edition separately. The Mac change log documents FLAC support. DSD, output controls and other unchecked capabilities remain `?`. Windows component support is not treated as Mac support.
