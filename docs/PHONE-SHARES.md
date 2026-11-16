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
| Played from a share | FLAC, ALAC and AAC (`.m4a`, `.mp4`, `.m4b`), WAV (also RF64), AIFF, MP3 |
| Counted as "Files that need the Mac", not listed | DSD (`.dsf`, `.dff`), APE, WavPack, TTA, Ogg, Opus, WMA, DTS, TrueHD/MLP, AC-3/E-AC-3, MKA, ISO, TAK |
| Covers | `cover`, `folder`, `front`, `album` or `albumart` `.jpg`/`.jpeg`/`.png` in the album's folder, else the picture inside a file |
| ReplayGain | Read from the file's own tags when Output › ReplayGain is on: Vorbis comments in FLAC, `TXXX` frames in ID3 (MP3, WAV, AIFF), named iTunes items in MPEG-4. Read again from the file each time a song is played, so an index made by an earlier version needs no rescan |
| Not there | Playlists (they are the Mac's), CUE sheets |

MP3 and AAC albums on a share join without a gap, like the lossless ones: the phone's decoder reads the encoder's delay and padding
from each file and leaves them out (see `docs/REMOTE-STREAMING.md`).

Folders a NAS keeps for itself (`@eaDir`, `#recycle`, `$RECYCLE.BIN`, `System Volume Information`, `lost+found`, snapshots), hidden files
and names starting with a dot are skipped. Songs without tags are filed by their folder and file name.

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
- The scan, the library and `ShareMac` on a made-up share in memory, including a share that stops answering mid-scan.
- Against a real server when one is named: `VESPERTINE_SMB="host:port/share/user/password" swift test --package-path
  Packages/VespertineRemoteKit --filter SMBLiveTests` (the share needs a `Music` folder; `VESPERTINE_SMB_FILE` names a local copy of
  `Music/random.bin` to compare a large read with). CI names none.

What has not been measured: a real NAS (Synology, QNAP, TrueNAS, a Mac's or Windows' file sharing), a real phone over Tailscale, and
keeping albums from a share on a phone.
Samba is what most NAS boxes run, but that is not the same as having tried them.
