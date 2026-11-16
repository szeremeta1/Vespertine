# Playing from an SMB share on the iPhone or iPad

The phone can play a music folder on a NAS (or any computer's shared folder) by itself: no Mac running, no Vespertine anywhere but on
the phone. Away from home the same share is reached over Tailscale or another VPN, by the address typed for it.

## Using it

First screen › **Add an SMB Share**. Type the share as `smb://server/share/folder` (also accepted: `//server/share`, `\\server\share`,
`server/share`, with an optional `user@` and `:port`), the account and the password. The app signs in once before it keeps the share, so
a wrong address or password is said in the form. The share then appears under **Your Shares** next to the paired Macs.

Opening a share scans it: the app walks the folders, reads each song's tags (a few kilobytes per file, never the whole file) and keeps
the list on the phone. The first scan of a large library over a slow line takes a while; what has been found so far can be browsed and
played while it runs, and a scan cut short (the app closed, the line dropped) carries on from where it stopped. Later scans read only
new and changed files. A scan runs by itself when a share is opened and its list is more than a day old, and from Output › **Scan
Again**.

A share is browsed and played with the same screens and the same player as a Mac's library when "This iPhone" is the output: the song's
own file is read from the share in pieces and decoded on the phone, so lossless and hi-res files reach the output as they are, with the
same read-back of what iOS does to them. Keeping albums on the device goes through the same code as with a Mac.

For the address, use a name or address that works where the phone is: the NAS's Tailscale name (`nas.tail1a2b3.ts.net`) or its
100.x address works at home and away as long as Tailscale is connected on the phone; a `.local` name or a 192.168 address works only at
home. Now Playing says **SMB share** as the source, and Output shows the share, whether it answers, and the network its address is on.

## What it opens, and what it doesn't

| | |
|---|---|
| Played from a share | FLAC, ALAC and AAC (`.m4a`, `.mp4`, `.m4b`), WAV (also RF64), AIFF, MP3, stereo or mono DSD (`.dsf`, `.dff`), and in stereo or mono: APE, WavPack (`.wv`), Ogg Vorbis (`.ogg`, `.oga`) and Opus (`.opus`, `.ogg`) |
| Counted as "Files that need the Mac", not listed | DSD in surround or packed with DST, WavPack holding DSD, APE, WavPack, Vorbis and Opus in surround, FLAC or Speex in Ogg, TTA, WMA, DTS, TrueHD/MLP, AC-3/E-AC-3, MKA, ISO, TAK |
| Covers | `cover`, `folder`, `front`, `album` or `albumart` `.jpg`/`.jpeg`/`.png` in the album's folder, else the picture inside a file (not read from inside APE, WavPack, Ogg and Opus files) |
| Not there | Playlists (they are the Mac's), CUE sheets, ReplayGain, gapless trim values for MP3/AAC |

Folders a NAS keeps for itself (`@eaDir`, `#recycle`, `$RECYCLE.BIN`, `System Volume Information`, `lost+found`, snapshots), hidden files
and names starting with a dot are skipped. Songs without tags are filed by their folder and file name.

## DSD from a share

The phone reads a DSF or DSDIFF file's audio itself (`DSDFile.swift`, `DSDRendering.swift`) and plays it one of two ways:

- **As DoP** to a USB DAC that passed "Play DSD natively?" on this phone, with the volume at 100%: the DSD bits go out unchanged
  inside 24-bit PCM at one sixteenth of the DSD rate (176.4 kHz for DSD64). Now Playing says **NATIVE DSD · DoP**. The rules are the
  ones for DSD from a Mac: an untested DAC, a DAC that stops below the carrier rate, or a volume below 100% gets PCM, never DoP.
- **As PCM** everywhere else (the speaker, AirPods, an untested DAC): the phone converts the DSD to 24-bit PCM at the highest rate
  of the song's family that the output takes, up to one eighth of the DSD rate (88.2, 176.4 or 352.8 kHz for DSD64). Now Playing
  says **CONVERTED ON THIS DEVICE**. The conversion is a linear-phase low-pass that keeps everything to 20 kHz (to 40 kHz at 176.4 kHz and
  above), with the 6 dB of gain usual for DSD, and peaks above full scale clipped.

Nothing is stored on the share or converted ahead of time: the phone reads the part of the file it needs as it plays or seeks. The
PCM is this app's own conversion, so it is not sample-for-sample what the Mac's converter makes of the same file. Surround DSD and
DST-packed DSDIFF (from an SACD) still need the Mac. A share scanned before this version lists its DSD files after its next scan
(by itself after a day, or **Scan Again**).

## APE, WavPack, Ogg Vorbis and Opus

iOS opens none of these, so the app brings a decoder for each (`Packages/VespertineDecoders`): the Monkey's Audio SDK, libwavpack,
libvorbisfile and opusfile. All four are BSD-3-Clause, and they are the same builds the Mac app decodes these files with, so a file
decodes to the same samples on the phone as on the Mac. The app carries no FFmpeg and nothing under the LGPL: the App Store exception
covers only Vespertine's own code, and a library that asks for relinking doesn't fit an App Store build. That is why TTA (LGPL), and
TAK, WMA, DTS and TrueHD (FFmpeg on the Mac) stay with the Mac. Their licenses are in the app under Settings › About › Licenses.

A file is decoded as it plays: the player is given PCM (whole numbers for APE and WavPack, 32-bit floats for Vorbis and Opus) and each
range it asks for is decoded from the frames it covers, so seeking works and nothing is converted ahead of time. Now Playing says
**ORIGINAL FILE**, as for a FLAC: the samples are the file's own. Reading in order, and any seek in APE, WavPack and Vorbis, gives
exactly the samples the Mac decodes. Opus carries what it has decoded from packet to packet, so a seek starts decoding a second early and
throws that second away: what plays is the same sound as reading in order, to within rounding.

Only stereo and mono play here. A share scanned before this version lists these files after its next scan (by itself after a day, or
**Scan Again**).

## The SMB client

`Packages/VespertineRemoteKit/Sources/VespertineShare` is a small read-only SMB client written for this app (Foundation and POSIX
sockets only; no third-party code), because the libraries that exist are under licenses that don't fit an App Store build.

- Dialects: SMB 2.0.2, 2.1, 3.0 and 3.0.2. Not SMB 1. Not servers that accept only SMB 3.1.1, and not shares that require
  encryption: both are said in plain words when adding the share.
- Sign-in: NTLMv2 inside SPNEGO, with the message integrity code and the mechanism-list signature. `user`, `DOMAIN\user` and
  `user@domain` are accepted. No Kerberos, no guest fallback.
- Every request after sign-in is signed (HMAC-SHA-256 on SMB 2, AES-CMAC with the SP 800-108 derived key on SMB 3) and every signed
  reply is verified; a reply whose signature is wrong is refused, and said.
- It only ever opens folders for listing and files for reading. There is no code path that writes, renames or deletes.
- The password is kept in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: this device only, not in iCloud Keychain
  or a backup restored elsewhere) and is used only to compute the NTLMv2 answer; it is never sent.
- A dropped connection (the phone changed networks, the server restarted) is made again and the request repeated once. A change of
  network lets go of the connections at once, so the next read goes over the new one instead of waiting out a dead line.

A share takes the place of a Mac behind the same interface (`ShareMac` is a `RemoteChannel`, as the demo is), so the library screens,
the queue, the player and kept albums are the ones a Mac's library uses. The index is `library.json` under Application Support, with
favorites beside it; covers are fetched when first shown and kept at the sizes asked for.

## How it is tested

- Digests and keys against the published vectors (RFC 1320, 1321, 2202, 4231, 4493, FIPS 180 and 197), NTLMv2 against the example in
  MS-NLMP 4.2.4, and the system's CryptoKit/CommonCrypto against the portable code where both exist.
- The client against recorded conversations with Samba 4.19 for SMB 2.0.2, 2.1 and 3.0.2 (`SMBRecordings.swift`): the same bytes
  must be sent, and the recorded replies' signatures must verify.
- The tag reader against files made with FFmpeg and checked with ffprobe (`SongFixtures.swift`).
- DSD (`DSDTests.swift`): DSF and DSDIFF files made in the test from a 1-bit modulator. As DoP, the words must equal the DoP test
  clip's (`DoPProbeClip`) for the same DSD, whatever the file kind, bit order or the way the reads are cut up. As PCM, a tone must come
  out at its level (within 0.2%) at every rate, and DSD silence as digital silence. On a Mac, the player's own decoder must read
  the stream back to the same 24-bit words.
- The decoders (`PhoneDecodersTests.swift` in VespertineKit, which has the Mac's decoder to compare with): APE at 16 and 24 bits,
  WavPack, Ogg Vorbis and Opus fixtures must decode to exactly the samples SFBAudioEngine decodes on the Mac, read in pieces; a read
  from any frame must be the same samples as reading in order (Opus: the same sound); DSD in WavPack and 5.1 Opus must be left to the
  Mac; a share that stops answering must be said as that, not as a damaged file. `DecodedFormatsTests.swift` covers the scan and
  `ShareMac` with a made-up decoder, and the player's own decoder reading 16, 24 and 32-bit and float samples back exactly.
- The scan, the library and `ShareMac` on a made-up share in memory, including a share that stops answering mid-scan.
- Against a real server when one is named: `VESPERTINE_SMB="host:port/share/user/password" swift test --package-path
  Packages/VespertineRemoteKit --filter SMBLiveTests` (the share needs a `Music` folder; `VESPERTINE_SMB_FILE` names a local copy of
  `Music/random.bin` to compare a large read with). CI names none.

What has not been measured: a real NAS (Synology, QNAP, TrueNAS, a Mac's or Windows' file sharing), a real phone over Tailscale, and
keeping albums from a share on a phone. DSD from a share has not been heard on a phone or seen on a DAC's display (bench B8, step 11). APE, WavPack, Ogg Vorbis and
Opus have been decoded on a Mac only: not yet built into an app on a phone, or heard there.
Samba is what most NAS boxes run, but that is not the same as having tried them.
