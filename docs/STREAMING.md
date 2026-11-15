# Streaming

Vespertine has no built-in client for any commercial streaming service. What it has is a receiver: other apps on your network send it music, and it plays that music through the same engine and the same signal path as a file.

## Receive from Other Apps (beta)

Off by default. The switch is in Settings › Playback, next to Network Players.

While it is off, Vespertine opens no socket for it, announces nothing, adds nothing to any menu and reads or writes nothing for it. While it is on, this Mac appears on your network as a UPnP media renderer. A control app (mconnect, BubbleUPnP, Linn Kazoo, or the app of a streaming service that can send to UPnP players) lists it by the name you give it, and sends it the address of a song. Vespertine fetches that address and plays it.

### What you see

- The song's title, artist, album and cover as the control app describes them.
- The signal path as for any file, with one more step at the top: "From *app*, over the network". Rate switching, exclusive access, the `BIT-PERFECT` badge and the rest are decided exactly as they are for a file of the same format.
- A chip beside the song says who is sending it, such as "FROM MCONNECT".
- The queue shows the control app's song and the one after it. They are the app's to order, so they can't be changed here.
- Your own queue is kept, paused and out of sight. It comes back when the control app stops, or when you play something of your own. The two never mix.
- If a song can't be played, Vespertine says why in plain words, and the control app is told too.

### Volume

The volume is yours by default: a control app can read it but can't change it. "Let those apps set the volume" allows it. On an output with no volume control of its own that means Vespertine's digital volume, which changes the samples below 100%, and the signal path says so.

### How TIDAL, Qobuz and others work with it

Vespertine contains no code for TIDAL, Qobuz, Apple Music, Spotify, Amazon Music or Deezer: no client ids, no sign-in, no private endpoints. Their terms don't offer a way for an open-source player to do that honestly.

Some of them work through the receiver anyway, because the signing in and the choosing happen in a control app that has its own agreement with the service. Apps such as mconnect and BubbleUPnP sign in to TIDAL or Qobuz with your account and hand the renderer an ordinary http address for each song. Vespertine plays that address like any other. What arrives is whatever the service sends that app (for these two, usually FLAC), and the signal path shows its real format once it plays.

Services that only send protected streams (Apple Music, Spotify, Amazon Music) can't be played this way: a protected stream is refused with a sentence that says so.

This has been tested against Vespertine's own test control point, not yet against the control apps named above. Reports are welcome.

### What it accepts

- One whole audio file over http or https, in any format Vespertine plays. The server has to allow reading from the middle of the file (HTTP range requests), which playing and seeking need.
- The next song, sent ahead (`SetNextAVTransportURI`), plays without a gap when the formats allow it, as two files do.
- Not accepted: playlists of segments (HLS, DASH), live streams with no length, protected streams, and anything that isn't audio.

OpenHome control is not part of this version.

### Safety

- Only http and https addresses are fetched. `file:` addresses, this Mac itself, link-local addresses and redirects to any of them are refused.
- "Only from this Mac's own networks" (on by default) takes control only from devices on a network this Mac is on. Off, any device with a private address may control it, such as one reaching this Mac through a VPN. Addresses on the public internet are never accepted.
- Descriptions, requests and song descriptions are size-limited and read by strict parsers. A song description with a document type or entities is refused.
- Nothing is kept. A song is staged in the transient playback cache while it plays, like a file from a network share, and removed afterwards. Its address is held in memory only: it is not written to disk, to a log or to the queue. Covers are held in memory only.
- The Mac stays awake while a control app's song plays. Quitting says goodbye on the network (`ssdp:byebye`).
- Songs a control app sends are not added to the library, not counted, and not sent to Last.fm or Discord.

### Limits

- Plays on this Mac's own outputs. While the chosen output is a network player or an AirPlay receiver, a control app's song is refused with a sentence that says why.
- The address is checked when it arrives and again on every redirect. A name that changes what it points at between the check and the fetch is not defended against beyond that.
- UPnP has no sign-in: any device allowed by the setting above can send music or stop it. Turn the switch off on networks you don't trust.
