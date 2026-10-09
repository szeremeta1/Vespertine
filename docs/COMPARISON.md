# Comparison sources and scope

The [README table](../README.md#compared-with-other-mac-players) and [website table](../site/index.html#compare) cover the same features. `?` means unverified. It is not a claim that a player lacks the feature. No prices or overall sound-quality rankings are included. Corrections welcome through [GitHub issues](https://github.com/szeremeta1/Vespertine/issues).

The starting point was the maintainer's October 9, 2026 competitor-review summary. The feature rows follow that review: file formats, output control, local surround, Spatial Audio, analysis, source availability, SACD ISO, convolution/plugins and streaming services. The primary pages below were checked for this documentation update; cells were filled again on October 9, 2026 from each product's own documentation, change log or source code. A `Yes` or `No` appears only where one of those says so; "vendor claim" marks a product's own bit-perfect statement that this page has not measured. A documented feature is not a Vespertine hardware test of a competitor.

## Vespertine

The [feature details](FEATURES.md), [signal-path conditions](../Packages/VespertineKit/Sources/VespertineAudio/SignalPath.swift) and [verification guide](VERIFICATION.md) describe what the app implements and how it is checked. The table says “conditions + tests” rather than claiming an independent loopback result.

Receiver bitstream and multichannel DAC output are experimental, untested on real receivers/multichannel DACs; reports wanted. Decoding, routing and carrier tests do not establish hardware compatibility. SACD ISO playback is new (two real discs tested against sacd_extract). There is no convolution, audio effect plugin hosting or streaming-service integration.

## Apple Music on Mac

The supplied October 2026 review reports third-party Nativerate loopback tests on an RME interface: bit-exact 16/24-bit PCM from 44.1 to 192 kHz on macOS 27.0.1, at 100% player volume. It also reports no automatic DAC rate switching, no hog mode, no FLAC/DSD, and a failed 32-bit test. The original third-party test report could not be independently rechecked for this update. The table attributes the 16/24-bit result to those tests and makes no claim about other configurations.

[Apple's lossless-audio support page](https://support.apple.com/en-us/118295) documents ALAC playback and manual selection of the Mac's output rate in Audio MIDI Setup. It is not the source of the macOS 27 bit-exact measurement. Unchecked local-surround and Spatial Audio cases remain `?`.

## Audirvana Studio and Origin

[Origin's product page](https://audirvana.com/audirvana-origin/) documents local FLAC and DSD, a one-time purchase without streaming services, and optional convolution. The supplied review covers native-rate/exclusive output and multichannel playback. [Audirvana's product page](https://audirvana.com/) distinguishes Studio's streaming integration from Origin's local library. [Audirvana's history](https://audirvana.com/about/) records AudioScan as a feature; hi-res analysis is not exclusive to Vespertine.

Audirvana's help center (articles marked as applying to Studio and Origin) documents [plugin hosting](https://help.audirvana.com/en/support/solutions/articles/202000051049-how-to-use-plugins-for-eq-or-acoustic-correction-in-audirv%C4%81na-) ("AudioUnits on macOS"), [supported formats](https://help.audirvana.com/en/support/solutions/articles/202000050817-which-audio-file-formats-are-compatible-with-audirv%C4%81na-) including DSF, DFF and ISO, [bit-perfect output by default](https://help.audirvana.com/en/support/solutions/articles/202000051094-is-audirv%C4%81na-bit-perfect-), automatic [exclusive access](https://help.audirvana.com/en/support/solutions/articles/202000072992-how-to-unlock-the-audio-ouput-), [AudioScan](https://help.audirvana.com/en/support/solutions/articles/202000051116-what-does-the-audioscan-results-mean-) and [multichannel playback to an AVR](https://help.audirvana.com/en/support/solutions/articles/202000059411-how-can-i-connect-my-device-to-audirv%C4%81na-). The [update history](https://help.audirvana.com/en/support/solutions/articles/202000096487-audirv%C4%81na-update-history) adds convolution in 2026, a paid option on Origin. Local Apple Spatial Audio remains `?`.

## Roon

[Roon's audio setup guide](https://help.roonlabs.com/portal/en/kb/articles/audio-setup-basics) documents exclusive mode, DSD strategies and output controls. [Multichannel](https://help.roonlabs.com/portal/en/kb/articles/multichannel) documents local files with up to eight channels. [Convolution](https://help.roonlabs.com/portal/en/kb/articles/dsp-engine-convolution) documents filters. FLAC, rate switching and streaming-service integration are included in the supplied comparison review. [Roon's supported-formats FAQ](https://help.roonlabs.com/portal/en/kb/articles/faq-what-audio-file-formats-does-roon-support) lists DSD only "in the DSF and DFF file formats", so SACD ISO is shown as not supported. Its [sound-quality page](https://roon.app/en/sound-quality) states unaltered reproduction (a vendor claim). Plugin hosting, analysis and local Apple Spatial Audio remain `?`.

## VeraVox

[VeraVox's FAQ](https://www.veravox.audio/faq.html) documents FLAC, DSD, SACD ISO, exclusive output and hi-res analysis. Its [technical documentation](https://www.veravox.audio/technical.html) and [exclusive-mode guide](https://www.veravox.audio/exclusive-mode-macos.html) describe the in-app bit-perfect loopback test. These are documented capabilities, not measurements made for this update. VeraVox is proprietary according to the supplied review and its [license](https://www.veravox.audio/eula.html). Its FAQ says it "does not perform room correction or convolution itself, by design", and its [home page](https://www.veravox.audio/) lists "No DSP" in the player path and "No streaming services. Local files and UPnP only". It can route to an external convolver through a virtual device.

## Colibri

[Colibri's product page](https://colibri-lossless.com/) lists FLAC and DSD. Its [FAQ](https://colibri-lossless.com/faq/) confirms automatic rate switching and says SACD ISO is unsupported. Its home page states exclusive/hog mode and "bit-perfect gapless playback" (a vendor claim). The FAQ says Qobuz and Spotify are not integrated; network radio is supported. Unchecked capabilities remain `?`.

## Cog

[Cog's site](https://cog.losno.co/) describes a free, open-source player and lists FLAC, DSD, DTS, TrueHD and head tracking. Its October 4, 2026 release notes document surround spatialization with Apple's renderer. The table therefore includes local surround and Apple Spatial Audio. Vespertine does not claim to be the only player offering them. Its [README](https://github.com/losnoco/Cog/blob/main/README.md) (GPL) describes an exclusive mode that "runs [the output device] at each track's sample rate", and the app reports each track as bit perfect, modified or unknown. These were checked against the source at commit fb2ed48 (October 7, 2026). SACD ISO, file analysis, plugin hosting and streaming remain `?`.

## foobar2000 for Mac

The [Mac download page](https://www.foobar2000.org/mac) and [Mac change log](https://www.foobar2000.org/changelog-mac) identify the Mac edition separately. The Mac change log documents FLAC support, "Exclusive audio output support" and "Apple Audio Unit DSP support" (both 2.5, April 2023). The [license](https://www.foobar2000.org/license) is proprietary ("All rights reserved"). DSD, rate switching and other unchecked capabilities remain `?`. Windows component support is not treated as Mac support.
