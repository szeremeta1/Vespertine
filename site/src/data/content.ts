// The words on the home page, as data, so llms.txt, llms-full.txt and the FAQ's JSON-LD say exactly what the page says.
// Strings are trusted HTML. Every claim here follows README.md, docs/FEATURES.md, docs/COMPARISON.md and the release notes;
// if one of those changes, change it here too.
import { app, links } from './app';

export const description =
  'Free, open-source Mac player for surround and hi-res collections: SACD and DVD-Video disc images, DSD, DTS CDs, DTS-HD MA, TrueHD and Dolby Atmos files, Spatial Audio on AirPods, room correction measured in your own room, and a bit-perfect signal path you can inspect.';

export const hero = {
  lede: `The free, open-source Mac player for surround and hi-res music collections. SACD and DVD-Video disc images, DSD, DTS CDs, DTS-HD MA, TrueHD and Atmos files share one library with your stereo albums, with head-tracked Spatial Audio on AirPods. Room correction measures your room with a USB microphone and corrects each speaker; it’s off until you turn it on. A signal path shows each step from file to output. In English and ${app.languages} other languages.`,
  fine: 'Channel-for-channel output and receiver bitstream are experimental, untested on real receivers and multichannel USB DACs (one Sony TV over HDMI has been tested: see docs/DEVICES.md); reports wanted.',
};

export const pillars = [
  {
    title: 'Surround in one library',
    text: 'SACD images and rips, DVD-Video discs, DTS CDs, DTS-HD MA and TrueHD sit next to your stereo albums and play as head-tracked Spatial Audio on AirPods. When an album comes in both, each song is listed once and the right version plays for your output.',
    icon: 'M17 14a3 3 0 1 1 0 6 3 3 0 0 1 0-6ZM9.5 9.5a10.6 10.6 0 0 0 0 15M24.5 9.5a10.6 10.6 0 0 1 0 15M5.5 5.5a16.3 16.3 0 0 0 0 23M28.5 5.5a16.3 16.3 0 0 1 0 23',
  },
  {
    title: 'A signal path you can check',
    text: 'Rates, word lengths, gain and channel processing, read back from Core Audio. The bit-perfect conditions are in the source, with automated tests, a loopback test and a hardware verification guide.',
    icon: 'M4 17h6l3-8 4 16 4-12 3 4h6',
  },
  {
    title: 'Checks hi-res files',
    text: 'Analysis flags padded bit depth and possible upsampling or lossy origin. Spectral verdicts are estimates, shown with their evidence and limits. The same analysis runs on a Linux server next to your files.',
    icon: 'M4 26c3-9 5-15 8-15s3 10 6 10 3-14 6-14 3 13 6 19M26 4v26',
  },
  {
    title: 'Open source you can audit',
    text: 'Free under the GPL. Read, build and change the player, including its output conditions and tests. No account, subscription, ads or telemetry.',
    icon: 'M7 8h20v14H7zM13 27h8M17 22v5M12 15.5l3 3 6-6',
  },
];

export type Scene = {
  id: string;
  jack: string;
  kicker: string;
  title: string;
  lede: string;
  body: string[];
  list?: string[];
  note?: string;
  links?: { href: string; text: string }[];
  shot: string;
  wall?: boolean;
  alt: string;
  float?: { shot: string; alt: string; caption: string };
  caption?: string;
};

export const scenes: Scene[] = [
  {
    id: 'signal-path',
    jack: 'Signal path',
    kicker: 'Bit-perfect',
    title: 'Every track at its native rate and depth.',
    lede: 'The signal path lists each step from the file to your DAC, read back from Core Audio, and says when something changed the samples.',
    body: [
      'Vespertine switches the device to each file’s rate and resamples, with Apple’s mastering-quality converter, only when the DAC can’t run it. <span class="mono nowrap">BIT-PERFECT</span> appears only when the conditions in the source are met: a native rate, nothing changing the samples, a word length that fits, and a device that is exclusive or not shared with another app. PCM playback has been tested up to 768 kHz and DSD256 on a Fosi Audio ZD3, and up to 384 kHz and DSD128 on a FiiO K11.',
    ],
    list: [
      'Exclusive (hog) mode keeps other apps off the device. In shared mode the volume keys and the Digital Crown adjust your DAC; in exclusive mode they can too, if you turn that on.',
      'Integer mode sends unprocessed 32-bit PCM straight to DACs that take integers.',
      'Match 16-bit sources (off by default) sends 16-bit files to DACs with a real 16-bit mode as 16-bit, not zero-padded.',
      'Gapless, including CUE-sheet albums split from one file.',
      'Remembers your DAC. If it isn’t connected, music plays on the best connected output and moves back when the DAC returns.',
      'Outputs without a volume control of their own (HDMI, optical, line-out) can use Vespertine’s volume, chosen per output. Below 100% the labels say it’s no longer bit-perfect.',
      'Hands your DAC back at the rate and depth it had before, when Vespertine quits.',
      'A built-in loopback test compares every sample Vespertine sends to a virtual device. It’s a software check, labelled as one, and never changes the <span class="mono nowrap">BIT-PERFECT</span> badge.',
    ],
    links: [
      { href: links.signalPath, text: 'The conditions in code' },
      { href: links.verification, text: 'Verify it yourself' },
      { href: links.loopback, text: 'What the loopback test proves' },
    ],
    shot: 'bit-perfect-fosi-zd3-24-96',
    alt: 'Vespertine playing Lazar Berman’s Liszt, Années de pèlerinage, from a 24-bit / 96 kHz FLAC: the inspector marks it bit-perfect and exclusive on a Fosi Audio ZD3, with each step of the signal path.',
    float: { shot: 'loopback-test', alt: 'The loopback test sheet: 24-bit at 44.1 and 96 kHz, 16-bit padded and a gapless pair, each bit-exact.', caption: 'Loopback test · software check' },
  },
  {
    id: 'room-correction',
    jack: 'Room correction',
    kicker: 'Room correction',
    title: 'Measure your room. Correct each speaker.',
    lede: 'Measure your room with a UMIK-1 or another calibrated USB microphone, and Vespertine fits filters to each speaker from what it hears at your seat.',
    body: [
      'Sweeps play through one speaker at a time, at one to five spots around your listening seat. Each speaker gets its own filters, designed from the measurement. They are mostly cuts: they take down the room’s peaks and boost broad dips only gently. The same measurement sets each speaker’s delay and level, so every speaker reaches your seat at the same time and the same loudness. Room correction is off by default, and playback stays bit-perfect while it’s off. When it’s on, the signal path says <span class="mono nowrap">ROOM CORRECTION</span>.',
    ],
    list: [
      'Three targets: Warm (the default), Gentle tilt and Flat. Correct the bass only or the full range, and redesign the filters later without measuring again.',
      'Imports filters from REW or Equalizer APO, with each speaker’s delay and level, and exports Equalizer APO text.',
      'Imports impulse responses (WAV, AIFF, CAF or FLAC) and plays them by convolution.',
      'Stereo and 5.1.',
      'The Room Portrait shows the speakers, your seat and each microphone spot as it’s measured. The Curve Reveal then turns the measured response into the predicted one, and a before/after switch compares them.',
    ],
    note: 'The “after” curve is predicted from the measurement and the filters, not measured. To see what the room really does, measure again with correction on.',
    links: [{ href: links.roomCorrection, text: 'How room correction works' }],
    shot: 'room-correction-predicted',
    alt: 'Vespertine’s predicted room correction for a stereo pair with the Warm target: for each speaker, the measured response, the target and the predicted response after correction, with a room peak near 120 Hz cut by 14 and 18 dB, and each speaker’s filters.',
    float: { shot: 'room-correction-portrait-detail', alt: 'The Room Portrait in the measurement wizard: left and right speakers, the seat, and five microphone spots around it, the first with the microphone on it.', caption: 'Room Portrait' },
  },
  {
    id: 'surround',
    jack: 'Surround',
    kicker: 'Surround & Spatial Audio',
    title: 'Your 5.1 discs, in the same library.',
    lede: 'Multichannel music plays as head-tracked Spatial Audio on AirPods, or folds down by channel layout on a stereo DAC.',
    body: [
      'DTS CDs decode to 5.1. SACD images, extracted SACD tracks, multichannel FLAC, TrueHD and DTS-HD MA render as head-tracked Spatial Audio on AirPods or fold down on a stereo DAC. Dolby Digital Plus with Atmos uses macOS’s object renderer; TrueHD Atmos and DTS:X play their channel bed. Channel-for-channel output is experimental, untested on real receivers and multichannel USB DACs (one Sony TV over HDMI has been tested: see docs/DEVICES.md); reports wanted.',
    ],
    list: [
      'Stereo and surround versions of an album are listed once; Vespertine plays whichever suits the output, or the one you pin.',
      'Dolby Digital, DD+ and DTS-CD receiver bitstream is experimental, untested on real receivers and multichannel USB DACs (one Sony TV over HDMI has been tested: see docs/DEVICES.md); reports wanted. Carrier tests use FFmpeg’s S/PDIF reader. TrueHD and DTS-HD MA passthrough is unsupported on macOS.',
      'Export for Spatial Audio as binaural stereo for headphones or multichannel ALAC for Apple devices, with tags and artwork.',
    ],
    shot: 'spatial-audio-airpods-max',
    alt: 'Elton John’s Goodbye Yellow Brick Road, a 24-bit / 88.2 kHz 5.1 album, playing as head-tracked Spatial Audio on AirPods Max, with the signal path and a meter for each channel.',
    float: { shot: 'stereo-and-surround-versions', alt: 'An album with stereo and 5.1 versions of each song, listed once.', caption: 'Stereo and 5.1, listed once' },
  },
  {
    id: 'discs',
    jack: 'Disc images & DSD',
    kicker: 'SACD, DVD-Video & DSD',
    title: 'Play the disc image itself.',
    lede: 'Point Vespertine at an SACD or DVD-Video image and it plays the music straight from it, with nothing mounted, extracted or written.',
    body: [
      'SACD <span class="mono">.iso</span> images play their stereo and 5.1 areas, DST-compressed or plain, titled from the disc’s own text. DST is decoded back to the exact DSD, so stereo goes to your DAC as native DSD over DoP where the DAC supports it, and 5.1 plays as head-tracked Spatial Audio on AirPods. The LPCM music on DVD-Video discs (an <span class="mono">.iso</span> or a <span class="mono">VIDEO_TS</span> folder) plays bit for bit, one album per title and a track per chapter.',
    ],
    list: [
      'Matched sacd_extract bit for bit on two real discs. Discs with a 5.0 area, only a multichannel area, or DSD128 and above are covered only by synthesized test images so far.',
      'DSF and DSDIFF from DSD64 to DSD512, DST-compressed DSDIFF included, go out as DoP to DACs that take the carrier rate, or convert to high-rate PCM. DoP is confirmed up to DSD256 on a Fosi Audio ZD3 and up to DSD128 on a FiiO K11; DSD512 over DoP is untested on hardware.',
      'DVD-Video LPCM at 16, 20 and 24 bits, 48 and 96 kHz, up to 8 channels. DVD-Audio isn’t supported, and encrypted (CSS) discs need a decrypted copy.',
    ],
    links: [{ href: links.dvd, text: 'DVD-Video details' }],
    shot: 'sacd-iso',
    alt: 'Brothers In Arms by Dire Straits playing straight from its SACD disc image: stereo DSD64 over DoP to a FiiO K11, with the NATIVE DSD · DoP badge and the decoder reading SACD image, DST (lossless).',
    float: { shot: 'dsd-native-dop-detail', alt: 'Claudja Barry’s Love for the Sake of Love as DSD128 over DoP to a Fosi Audio ZD3, at 352.8 kHz.', caption: 'DSD128 · DoP · 352.8 kHz' },
  },
  {
    id: 'analysis',
    jack: 'Analysis',
    kicker: 'Fake hi-res detection & spectrum',
    title: 'Find out which “hi-res” files aren’t.',
    lede: 'Every file can be analyzed for its real bit depth, its real bandwidth and the fingerprints of lossy encoders and resamplers.',
    body: [
      'Verdicts come with their evidence and name what else could explain it, and a <em>Suspect Hi-Res</em> playlist collects them. Only zero padding is exact: the spectral verdicts are flagged as questions, because some high-bitrate lossy files pass as genuine and steep mastering filters, FM sources and tape or vinyl transfers can look suspicious. While music plays, meters and a live spectrum show what’s going out, DoP included.',
    ],
    list: [
      '16-bit audio padded into 24-bit containers',
      'Likely upsampled CD-quality masters sold as 96 or 192 kHz',
      'Likely lossy origin: MP3 or AAC transcoded to FLAC',
      'Likely synthetic high frequencies from SBR or “AI enhancement”',
      '<span class="mono">vespertine-analyze</span> runs the same analysis on a Linux server next to your files; the app imports the results.',
    ],
    note: 'The file in this screenshot is a deliberate fake: the trailer’s own music, encoded to MP3 and upsampled to 24/192 under a made-up band name.',
    links: [{ href: links.analysis, text: 'How the analysis works, and where it misses' }],
    shot: 'fake-hi-res-detection',
    alt: 'The Analysis tab flagging a 24/192 “remaster” as a likely lossy origin: its long-term spectrum stops at 16 kHz.',
  },
  {
    id: 'airpods',
    jack: 'AirPods Max',
    kicker: 'AirPods Max over USB-C',
    title: 'Lossless on AirPods Max, and it says so.',
    lede: 'Connected with the USB-C cable, AirPods Max are recognized as a 24-bit / 48 kHz lossless device.',
    body: [
      '48 kHz music plays bit-perfect and everything else is converted with Apple’s mastering-quality resampler, in plain view. Over Bluetooth, Vespertine tells you the link is AAC. This rests on Apple’s description of the cable path and Core Audio’s readback, since AirPods have no digital output to loop back.',
    ],
    shot: 'smart-playlist',
    alt: 'A smart playlist of 24-bit / 48 kHz tracks, narrowed to Oasis, playing bit-perfect on AirPods Max over USB-C.',
  },
  {
    id: 'library',
    jack: 'Library',
    kicker: 'Library',
    title: 'Browse like Apple Music. Manage like a librarian.',
    lede: 'Albums, artists, songs and genres, each with filters you can combine, and Shuffle for any of them.',
    body: [],
    list: [
      'Filters for format, 24-bit, 88.2 kHz and up, multichannel, genre, year, sample rate, channels and analysis verdict. Search ignores case and accents.',
      'Smart playlists in the units you think in: 24-bit, 88.2 kHz.',
      'Remasters, mono and stereo releases and SACDs of one album share a card; choose the edition when you open it.',
      'Favorites and play counts, kept in the library and never written to your files. Imports M3U and Apple Music playlists, play counts and favorites.',
      'Tag editor with backups and one-step revert, plus MusicBrainz enrichment that shows its confidence before writing anything.',
      'Network shares over SMB, NFS or WebDAV, with caching, Keep Offline and playback built for slow servers: tracks are buffered on your Mac before they play, with a loading ring on the play button while they do.',
      'Find Music searches every drive for your real music and leaves the clutter behind. A short setup on first launch picks your output and explains what exclusive access and ReplayGain do.',
      'Parametric EQ per output that imports AutoEQ and Equalizer APO presets. Off by default; when it’s on, the signal path says <span class="mono nowrap">EQUALIZER</span> instead of <span class="mono nowrap">BIT-PERFECT</span>.',
      'Mini player, menu-bar extra, media keys, ReplayGain and automatic, signed updates.',
    ],
    links: [{ href: links.features, text: 'Every feature, in detail' }],
    shot: 'genres',
    alt: 'The Genres page: a tile per genre with a mosaic of its covers.',
  },
  {
    id: 'languages',
    jack: 'Languages',
    kicker: `${app.languages} languages`,
    title: 'Speaks your language.',
    lede: `Every menu, setting and signal-path message is translated into ${app.languages} languages besides English.`,
    body: [
      'From Ukrainian, German and Japanese to Swahili, Tamil and Hausa, with local plurals and number formats, and Simplified, Traditional and Hong Kong Chinese each with their own vocabulary. Arabic, Hebrew, Persian and Urdu get a right-to-left layout.',
      'How the translations are checked: an automatic check on every change confirms every string in the app exists in all 44 languages with the same placeholders and the plural forms each language needs, and the main screens were checked in several languages for clipped or overlapping text and right-to-left mirroring. They began as careful machine translations, so corrections from native speakers are very welcome on <a href="https://github.com/szeremeta1/Vespertine/issues/new/choose">GitHub</a>.',
    ],
    wall: true,
    shot: 'languages',
    alt: 'Vespertine written in each of its 45 interface languages, from ヴェスパタイン and Веспертайн to فسبرتاين and वेस्परटाइन, at mixed sizes and typefaces.',
  },
];

export const badges = [
  { text: 'Bit-perfect', tone: 'brass' },
  { text: 'Exclusive' },
  { text: '32 / 192' },
  { text: '44.1 → 48 <span class="unit">kHz</span>', tone: 'copper' },
  { text: 'DSD 128 · <span class="unit">DoP</span>' },
  { text: 'Room correction', tone: 'copper' },
  { text: 'Spatial · head tracked' },
  { text: 'Synthetic high frequencies?', tone: 'copper' },
];

export const marquee = ['FLAC', 'DSD', 'SACD ISO', 'Dolby Atmos', 'DVD-Video', 'TrueHD', 'DTS-HD MA', 'ALAC', 'DTS CD', 'WavPack'];

export const formats = [
  { name: 'FLAC, ALAC, WAV, AIFF', text: 'Native rate and depth up to 32-bit and the rate your DAC runs (tested to 768 kHz); unchanged 32-bit PCM needs integer mode. CUE-sheet images.', ext: '.flac .m4a .wav .aiff .cue' },
  { name: 'DSD64 – DSD512', text: 'DSF and DSDIFF, DST-compressed or plain. DoP depends on the DAC and carrier rate, otherwise PCM. DoP is tested to DSD256; DSD512 over DoP is untested on hardware.', ext: '.dsf .dff' },
  { name: 'SACD images', text: 'Stereo and multichannel areas, DST or plain, straight from the image; each song listed once with its stereo and 5.1 versions.', ext: '.iso' },
  { name: 'DVD-Video LPCM', text: '16, 20 and 24-bit at 48 and 96 kHz, 1 to 8 channels, bit for bit; one album per title, a track per chapter. DVD-Audio isn’t supported.', ext: '.iso VIDEO_TS' },
  { name: 'Dolby Atmos', text: 'Dolby Digital Plus with Atmos, rendered by macOS’s object renderer, or its decoded channel bed.', ext: '.ec3 .m4a .mp4' },
  { name: 'Dolby TrueHD, MLP', text: 'Lossless, can be bit-perfect; TrueHD Atmos plays its channel bed, its objects aren’t rendered.', ext: '.thd .mlp .mka' },
  { name: 'DTS-HD Master Audio, DTS-HD HR, DTS', text: 'MA is lossless and can be bit-perfect; DTS:X plays its channel bed. Raw DTS decodes; DTS-CD bitstream is a separate path.', ext: '.dts .dtshd .mka' },
  { name: 'Dolby Digital (Plus)', text: 'Decoded by macOS. Receiver bitstream is experimental, untested on real receivers and multichannel USB DACs (one Sony TV over HDMI has been tested: see docs/DEVICES.md); reports wanted.', ext: '.ac3 .ec3' },
  { name: 'DTS CDs and DTS-WAV', text: 'Recognized and decoded to 5.1, including CUE-split albums.', ext: '.wav .flac .cue' },
  { name: 'APE, WavPack, TTA', text: 'Lossless. DSD inside WavPack isn’t supported.', ext: '.ape .wv .tta' },
  { name: 'Opus, Vorbis, Musepack, MP3, AAC', text: 'Decoded and marked lossy.', ext: '.opus .ogg .mpc .mp3 .m4a' },
];

export const compare = {
  intro: 'Several Mac players offer bit-perfect playback. This compares what each player’s own documentation or source code says. “Not documented” means the vendor doesn’t say either way, not that the feature is missing. Vespertine’s convolution is for room correction; it has no audio effect plugins or streaming services.',
  players: ['Vespertine', 'Apple Music (Mac)', 'Audirvana Studio / Origin', 'Roon', 'VeraVox', 'Colibri', 'Cog', 'foobar2000 for Mac'],
  rows: [
    ['Source code', 'GPL-3.0', 'Closed', 'Closed', 'Closed', 'Closed', 'Closed', 'GPL-2.0', 'Closed'],
    ['FLAC / DSD files', 'Yes / Yes', 'No / No', 'Yes / Yes', 'Yes / Yes', 'Yes / Yes', 'Yes / Yes', 'Yes / Yes', 'Yes / No⁴'],
    ['Automatic DAC rate switching', 'Yes', 'No', 'Yes', 'Yes', 'Yes', 'Yes', 'Yes', 'Not documented'],
    ['Exclusive (hog) mode', 'Yes', 'No', 'Yes', 'Yes', 'Yes', 'Yes', 'Yes', 'Yes'],
    ['16/24-bit PCM without sample changes', 'Conditions + tests', 'macOS 27: third-party tests¹', 'Vendor claim', 'Vendor claim', 'In-app loopback test', 'Vendor claim', 'In-app indicator', 'Not documented'],
    ['Local surround files', 'Yes²', 'Not documented', 'Yes', 'Yes', 'Yes', 'Not documented', 'Yes', 'Not documented'],
    ['Apple Spatial Audio for local surround', 'Yes', 'Catalog Atmos only³', 'Not documented', 'Not documented', 'Not documented', 'Not documented', 'Yes', 'Not documented'],
    ['Hi-res file analysis', 'Yes', 'No', 'AudioScan', 'Dynamic range, loudness', 'Yes', 'Not documented', 'No (live spectrum only)', 'No (live spectrum only)'],
    ['SACD ISO', 'Yes', 'No', 'Yes', 'No (DSF/DFF only)', 'Yes', 'No', 'No', 'No⁴'],
    ['Room correction', 'Measured in the app (USB mic), or REW / APO and impulse-response import', 'No', 'Via convolution (Origin: paid option) or Audio Units', 'Via convolution', 'No (by design)', 'Not documented', 'No', 'Not documented'],
    ['Convolution / audio effect plugins', 'Yes (room correction) / No', 'No / No', 'Yes (Origin: paid option) / Audio Units', 'Yes / No', 'No / No', 'Not documented / Not documented', 'No / No', 'Not documented / Audio Units'],
    ['Streaming services', 'No', 'Apple Music', 'Studio: yes; Origin: no', 'Yes', 'No (local + UPnP)', 'No (internet radio)', 'No (internet radio)', 'No (internet radio)'],
  ],
  notes: [
    '¹ Apple Music on macOS 27 was bit-exact at 16/24-bit in <a href="https://www.audiosciencereview.com/forum/index.php?threads/music-app-on-macos-27-and-ios-27-finally-plays-bit-perfect.73373/">third-party loopback tests reported on ASR</a>, at 100% volume. This is not a Vespertine measurement; the original report could not be independently rechecked for this update. There is still no automatic rate switching, hog mode, FLAC or DSD on Mac.',
    '² Multichannel DAC output and receiver bitstream are experimental, untested on real receivers and multichannel USB DACs (one Sony TV over HDMI has been tested: see docs/DEVICES.md); reports wanted.',
    '³ Apple documents Spatial Audio with head tracking for Dolby Atmos tracks in the Apple Music catalog, not spatial rendering of your own multichannel files.',
    '⁴ Tested on foobar2000 2.26 (macOS 27.0.1), with no components: DSF, DFF and SACD ISO files fail with “Unsupported file format”. DSF and DFF play only as 352.8 kHz PCM after installing FFmpeg separately and adding them to its FFmpeg Decoder Wrapper; SACD ISO still fails.',
  ],
};

export const faq = [
  {
    q: 'Is it really free?',
    a: 'Yes. Vespertine is free and open source under the GPL-3.0. There’s no account, no subscription, no ads and no telemetry (<a href="/privacy.html">privacy</a>). It only goes online to check for updates, and to reach MusicBrainz, the Cover Art Archive or ListenBrainz, or to find covers for your Discord status, when you ask it to.',
  },
  {
    q: 'What do I need?',
    a: `macOS ${app.minMacOS} (${app.minMacOSName}) or later, on Apple silicon or Intel. Intel hardware is untested; the Intel build has run under Rosetta, and reports from real Intel Macs are welcome.`,
  },
  {
    q: 'How do I install and update it?',
    a: `Download the DMG, open it and move Vespertine to Applications. It’s signed with a Developer ID and notarized by Apple, and it updates itself; every update is signed. With Homebrew: <code>${app.brew}</code>, then <code>${app.brewUpgrade}</code> or the app’s own updates.`,
  },
  {
    q: 'Does it stream from Qobuz, TIDAL or Apple Music?',
    a: 'No. Vespertine plays music you own, on your Mac, on external drives or on a network share. DRM-protected Apple Music subscription downloads cannot be played.',
  },
  {
    q: 'How do I know it’s actually bit-perfect?',
    a: `The signal path reads back what Core Audio actually did: the device’s nominal rate, its physical format and who holds it. The decoders have automated tests (TrueHD against its source, DTS against FFmpeg’s own decoder), a built-in loopback test checks the software path sample by sample, and <span class="mono nowrap">vespertine-probe</span> lets you check your own hardware. <a href="${links.verification}">How to verify it yourself</a>.`,
  },
  {
    q: 'Does it do room correction?',
    a: `Yes. Measure your room with a UMIK-1 or another calibrated USB microphone at one to five spots around your seat, and Vespertine fits filters to each speaker and lines up their delay and level, in stereo or 5.1. It also imports REW and Equalizer APO filters and impulse responses. It’s off by default, playback stays bit-perfect while it’s off, and the signal path says <span class="mono nowrap">ROOM CORRECTION</span> while it’s on. <a href="${links.roomCorrection}">How room correction works</a>.`,
  },
  {
    q: 'Can it play SACD and DVD discs?',
    a: 'It plays their images. SACD <code>.iso</code> images, stereo and multichannel, DST-compressed or plain, and the LPCM music on DVD-Video images or <code>VIDEO_TS</code> folders play straight from the image, with nothing extracted. DVD-Audio isn’t supported, and encrypted (CSS) DVDs need a decrypted copy.',
  },
  {
    q: 'Does it play Dolby Atmos?',
    a: 'Dolby Digital Plus with Atmos plays through macOS’s object renderer, as head-tracked Spatial Audio on AirPods. TrueHD Atmos and DTS:X play their lossless channel bed; their objects aren’t rendered. Bitstream to an AV receiver is experimental, untested on real receivers; reports wanted.',
  },
  {
    q: 'Will it change my files?',
    a: 'Only when you edit tags, and then each file is backed up first and can be reverted in one step. Folders are referenced in place; importing makes APFS clones that take no extra space.',
  },
  {
    q: 'Which hardware has it been tested on?',
    a: `PCM playback has been tested up to 768 kHz and DSD256 on a Fosi Audio ZD3, and up to 384 kHz and DSD128 on a FiiO K11, where integer mode was tested too. It has also been tested on AirPods Max over USB-C and Bluetooth, MacBook Pro speakers, and a Sony TV over HDMI in 5.1. Intel hardware is untested. Receiver bitstream and multichannel DAC output are experimental, untested on real receivers and multichannel USB DACs (one Sony TV over HDMI has been tested: see docs/DEVICES.md); <a href="${links.dacReport}">reports wanted</a>.`,
  },
  {
    q: 'Is it in my language?',
    a: `Probably: the interface is in English and ${app.languages} other languages, including right-to-left Arabic, Hebrew, Persian and Urdu. Vespertine follows the language set for it in System Settings. Corrections from native speakers are welcome on <a href="${links.newIssue}">GitHub</a>.`,
  },
];

export const support = [
  { title: 'Sponsor on GitHub', text: 'Vespertine is free. If it’s useful to you, a sponsorship on GitHub supports its development.', href: links.sponsors, cta: 'Become a sponsor' },
  { title: 'Report your DAC', text: 'Tell us what your DAC, interface or receiver did. Every device report widens what’s been checked on real hardware.', href: links.dacReport, cta: 'File a device report' },
  { title: 'Fix a translation', text: `Spot a clumsy phrase in one of the ${app.languages} languages? Open an issue with the better wording.`, href: links.newIssue, cta: 'Suggest a correction' },
  { title: 'Read the code', text: 'Bug reports, pull requests and questions are welcome. The signal-path conditions and their tests are all in the repository.', href: links.repo, cta: 'Source on GitHub' },
];
