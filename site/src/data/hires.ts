// The words on /hi-res-audio-player-for-mac/ (English only). Every claim follows docs/FEATURES.md,
// docs/VERIFICATION.md, docs/LOOPBACK.md, docs/ANALYSIS.md, docs/DEVICES.md and docs/COMPARISON.md (Apple's pages);
// nothing here is new. If one of those changes, change this page with it and bump `updated` in guides.ts.
// Strings are trusted HTML. Versions, sizes and install commands come from app.ts and the releases, never from here.
import { app, links } from './app';

export const hires = {
  path: '/hi-res-audio-player-for-mac/',
  title: 'Hi-res audio player for Mac with a signal path you can check · Vespertine',
  description: 'Vespertine is a free, open-source hi-res audio player for Mac: FLAC, ALAC and DSD, SACD images, and a signal path that shows when playback is bit-perfect and what changed the samples when it is not.',
  crumb: 'Hi-res audio player for Mac',
  ogAlt: 'Vespertine, a free hi-res audio player for Mac: its signal path shows a 24-bit / 96 kHz FLAC playing bit-perfect on a Fosi Audio ZD3.',
  eyebrow: 'Hi-res audio player for Mac',
  h1: 'A hi-res audio player for Mac that shows you what it did to the signal.',
  lede: 'Vespertine is a free, open-source Mac music player for your own hi-res files. It plays each track at its native rate and depth, and its signal path lists every step from the file to your DAC, read back from Core Audio, so you can see whether playback was bit-perfect instead of taking it on faith.',

  rate: {
    title: 'What hi-res playback takes on a Mac',
    paragraphs: [
      `Hi-res playback on a Mac starts with the output rate. Apple’s own advice, in <a href="https://support.apple.com/en-us/108326">Play high sample rate audio on your Mac</a>, is to choose the output rate by hand in Audio MIDI Setup and match it to the sample rate of your source material.`,
      `Vespertine does that for you: it switches the DAC to each track’s native rate. If the DAC can’t run that rate, Apple’s mastering-quality resampler converts it, and the signal path says so. Per-device settings can match the source, use the device’s maximum rate, or force a rate, and when Vespertine quits each device goes back to its earlier rate and depth.`,
      `PCM playback has been tested up to 768 kHz and DSD256 on a Fosi Audio ZD3, and up to 384 kHz and DSD128 on a FiiO K11 (developer reports; see docs/DEVICES.md). That is the hardware that has been tried; other DACs are untested, and <a href="${links.dacReport}">DAC reports are welcome</a>.`,
    ],
  },

  formats: {
    title: 'What it plays: FLAC, ALAC, DSD, SACD images and more',
    lead: `Vespertine plays music you own, on local drives and on SMB, NFS or WebDAV shares. It does not stream from Qobuz, TIDAL or Apple Music, and it can’t play DRM-protected files. The rows below are from the formats table on the <a href="/#formats">home page</a>.`,
    // Which rows of the home page's formats table (content.ts, English) this page shows, by name.
    rows: ['FLAC, ALAC, WAV, AIFF', 'DSD64 – DSD512', 'SACD images', 'DVD-Video LPCM', 'APE, WavPack, TTA'],
    tail: `Dolby TrueHD, DTS-HD Master Audio and Dolby Atmos files play too; the <a href="/#formats">full list</a> has them.`,
  },

  bitPerfect: {
    title: 'How to check that it’s bit-perfect',
    paragraphs: [
      `The signal path lists decoding, device rate and physical format, gain, resampling and channel processing. <span class="mono nowrap">BIT-PERFECT</span> appears only when the rate is native, no processing changes the samples, the word length fits, and the device is exclusive or no other app is detected playing to it. The conditions are in <a href="${links.signalPath}">the code</a>, so you can read exactly what the badge means.`,
      `The badge has limits, and Vespertine says so. Shared-mode checks poll about once a second, so short sounds and activity Core Audio doesn’t report can escape detection. Processing inside a DAC or headphones is outside what macOS reports. A signal-path badge is not an independent digital loopback measurement.`,
      `For the software path there is a <a href="${links.loopback}">built-in loopback test</a> (Settings › Playback, or Controls › Loopback Test…). It plays a test signal through a virtual loopback device and checks that every sample comes back unchanged, from 44.1 to 384 kHz at 16, 24 and 32 bits, including gapless joins. It checks the decoder, the engine and Core Audio, not a DAC, so it never changes the BIT-PERFECT badge. The <a href="${links.verification}">verification guide</a> shows how to check your own hardware.`,
    ],
    needs: `Built-in speakers and the headphone jack use shared mode, and speakers and virtual or aggregate devices are never labelled BIT-PERFECT.`,
  },

  fake: {
    title: 'Is that “hi-res” file really hi-res?',
    paragraphs: [
      `Vespertine can analyze each file for its real bit depth, its real bandwidth and the fingerprints of lossy encoders and resamplers. Zero-padded bit depth is detected exactly. Possible upsampling, lossy origin and synthetic high frequencies are spectral estimates, shown as questions with the measurements and alternative explanations beside them.`,
      `It can be wrong in both directions: steep mastering filters, FM sources and tape or vinyl transfers can look suspicious, and some high-bitrate lossy sources pass undetected. <a href="${links.analysis}#limits">How the analysis works and where it misses</a>.`,
    ],
  },

  install: {
    title: 'Install',
    lead: `Free and open source (${app.licenseName}). No account, subscription, ads or telemetry. It needs macOS ${app.minMacOS} (${app.minMacOSName}) or later, on Apple silicon or Intel; Intel hardware is untested.`,
  },

  faq: [
    {
      q: 'Does Vespertine change my DAC’s sample rate?',
      a: 'Yes, it switches the DAC to each track’s native rate. If the DAC can’t run the source rate, Apple’s mastering-quality resampler converts it, and the signal path shows the conversion. When Vespertine quits, each device is restored to its earlier rate and depth, or the default you chose.',
    },
    {
      q: 'Does the BIT-PERFECT badge prove playback was bit-perfect?',
      a: 'It shows the conditions Vespertine can see are met: native rate, no sample-changing processing, a word length that fits, and an exclusive device or no other app detected. It is not an independent loopback measurement, and anything inside the DAC or headphones is outside what macOS reports. The built-in loopback test checks the software path sample by sample.',
    },
    {
      q: 'Can it play 32-bit files unchanged?',
      a: 'With integer mode. That needs exclusive access and a DAC with a non-mixable 32-bit integer format; it then sends unprocessed PCM as integers, including 32-bit recordings. The normal Float32 path preserves up to 24 significant bits.',
    },
    {
      q: 'Does DSD play as DSD or as PCM?',
      a: `DSF and DSDIFF files decode from DSD64 to DSD512. On a DAC marked DoP-capable, DSD is packed into DoP frames when the DAC supports the carrier rate; otherwise it becomes high-rate PCM, with the conversion shown in the signal path. DoP is reported to work up to DSD256 on a Fosi Audio ZD3 and up to DSD128 on a FiiO K11 (developer reports, no capture); DSD512 over DoP has not been tested on hardware.`,
    },
    {
      q: 'Can it tell me if a hi-res file is an upsampled CD rip?',
      a: 'It can flag it. Analysis shows zero-padded bit depth exactly, and possible upsampling or lossy origin as estimates with the measurements behind them. They are estimates, not verdicts: some genuine files look suspicious, and some high-bitrate lossy sources pass undetected.',
    },
    {
      q: 'Can I get bit-perfect playback from the Mac’s speakers or headphone jack?',
      a: 'Not labelled as such. The built-in speakers and headphone jack use shared mode, and speakers and virtual or aggregate devices are not labelled BIT-PERFECT. The badge looks for a native rate, unprocessed samples and exclusive access to the device, which is what an external DAC can give it.',
    },
  ],
};
