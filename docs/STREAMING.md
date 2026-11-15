# Streaming

Vespertine has no built-in client for any commercial streaming service. It has two things, each off by default behind its own switch:

- A receiver. Other apps on your network send it music, and it plays that music through the same engine and the same signal path as a file. See [Receive from Other Apps](#receive-from-other-apps-beta).
- A client for your own music server. Servers that speak the open OpenSubsonic API (Navidrome, Gonic, Airsonic and others) get their own section in the sidebar, and their songs play like your files. See [Music servers](#music-servers-opensubsonic-beta).

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

## Music servers (OpenSubsonic, beta)

Off by default. The switch is "Music Servers (OpenSubsonic, beta)" in Settings › Library, under Sources, next to your folders and network shares.

OpenSubsonic is the open API at [opensubsonic.netlify.app](https://opensubsonic.netlify.app). It is spoken by servers you run yourself, such as Navidrome, Gonic and Airsonic. It is not a commercial service, and there is no account with anyone but your own server.

### What you see

- Each server under Music Servers in the sidebar. Selecting it shows that server's albums.
- Albums, Artists, Songs, Genres and Recently Added, and the counts beside them, show your files only. An album you hold as files and on the server stays in Albums as one album with two copies, and the copies list says which is which.
- Search, Favorites, playlists and history include the server's songs. A server's song carries a small house-and-note glyph beside its format, and pointing at it names the server. Song lists also gain a Source column while a server is on.
- A song's format as the server lists it, followed by "≈", until Vespertine has played the song. Once played, the format is what was read, and the "≈" goes.
- The signal path as for any file. Vespertine asks the server for the original file (`format=raw`). If the server sends something else anyway, the signal path says "Converted by the server" and the badge is never `BIT-PERFECT`.
- Seeking reads from the middle of the file by HTTP range, as it does for a file on a share. Two songs in a row play without a gap when their formats allow it, as two files do.
- If the server goes away while you listen, what has already arrived keeps playing. Once the music runs out and the server has sent nothing for 15 seconds, playback stops and Vespertine says "Home isn't answering." with your server's name, in the player and on the server's row in Settings. It does not move on to the next song, which would wait for the same server. Playing a song from the server again, once it is back, clears the message. A slow connection that is still sending is not given up on.
- Adding a server's song to Favorites stars it on the server, and the server's starred songs are favorites here.
- "Tell the server what I play" is its own switch, off by default. On, each song that counts as played is reported to the server (`scrobble`), as the server's own apps do.

### Signing in

You type the server's address, your user name, and either a password or an API key (for servers with OpenSubsonic's API key extension).

- With a password, Vespertine makes a token from it and a random salt, as the API describes, and keeps the token and salt. The password itself is kept only for a server that accepts nothing else.
- What is kept is one item in your login Keychain per server, under the service `org.szeremeta.vespertine.streaming.opensubsonic`. Nothing of it is written to Vespertine's settings, its library database, a log, the phone remote, or an address on disk. Signing out deletes the item.
- An `https` address is the default. An `http` address is accepted only when every address the server's name resolves to is on your own network (this Mac, a private range, a link-local address, or the range overlay networks such as Tailscale hand out), and the sign-in sheet warns that the sign-in then travels unencrypted. macOS itself refuses plain `http` to a full host name; an IP address, a `.local` name or a bare host name works.
- A redirect is followed only to the same host, and never from `https` to `http`.

Several servers can be added. Each is an account under the one switch.

### What is not in this version

- No offline copies of a server's music. Songs are streamed through the transient playback cache and removed afterwards.
- No editing of a server's tags or playlists from Vespertine, and no analysis of a server's songs (analysis reads a file).
- A server's songs can't be sent on to a phone by the remote's own streaming.
- Not yet tested against a real Navidrome, Gonic or Airsonic server: the tests use Vespertine's own test server over loopback. Reports are welcome.

## The rules every streaming provider is held to

Music servers are built on a small core (`VespertineStreaming`) that any later provider would also have to go through. The core enforces these rules itself; they are not left to each provider.

1. **Off is off.** Each provider has one switch, `streaming.<id>.enabled`, registered off. While it is off the provider is never constructed, no request leaves the Mac for it, its Keychain item is not read, and its songs are left out of every library query: the counts, albums, artists, genres, songs, playlists, smart playlists, favorites, history and search. Nothing but the switch itself shows. Turning it off deletes nothing, and turning it on brings everything back.
2. **Credentials only in the Keychain.** One generic-password item per provider and account in the login Keychain, service `org.szeremeta.vespertine.streaming.<id>`. Never in settings, the database, a log, crash text, the remote protocol, or an address written to disk. Signing out deletes the item. No client secret of any service is in the repository; a provider that needed a build-time secret would read it from a git-ignored resource and say "Not available in this build" without it.
3. **No audio on disk unless the terms allow it.** A stream lives in the transient playback cache and is deleted when the song is let go. A provider declares `.transientCacheOnly` or `.offlineAllowed(termsReference:)`. For the first, the cache refuses to pin, copy or export its streams. OpenSubsonic is your own server and declares the second, but no offline copy is offered yet.
4. **An honest verdict.** A provider that hands over the bytes (`.engine`) is played by Vespertine's engine and gets the normal signal path. A provider whose own player makes the sound (`.external`; none exists) can never read `BIT-PERFECT`. A stream that is not the file the server lists is marked as converted and can't read `BIT-PERFECT` either. A format that is only listed, not yet played, is marked "≈".
5. **One gate per provider.** Every request of a provider goes through one gate, which spaces them, lets playback go ahead of background listing, and backs off when the server answers 429 or 503 with `Retry-After` (60 seconds when the server names no time). Settings then says in a plain sentence that the server asked Vespertine to wait, and for how long.
6. **Library rows carry a source.** A provider's songs are rows of the one library, tied to a source that names the provider and a random account id. That is what lets an album held as files and on a server be one album with two copies. The migration that made room for them adds only empty tables and columns.

### The provider contract

A provider implements `StreamingProvider`:

| Member | What it is for |
|---|---|
| `id`, `account` | The provider's id (lower case, such as `opensubsonic`) and which of its accounts this instance reads. |
| `capabilities` | What it can do: search, library, playlists, favorites, play reports, range requests, several accounts. The app shows only what is listed. |
| `playbackMode` | `.engine` (hands over bytes) or `.external` (its own player makes the sound). |
| `storagePolicy` | `.transientCacheOnly` or `.offlineAllowed(termsReference:)`. |
| `session()`, `signIn(_:)`, `signOut()` | Whether there is a credential (Keychain only, no network), checking what was typed with the server and keeping the least needed, and deleting it. |
| `search`, `library`, `tracks(of:)` | Listing. |
| `openStream(_:)` | A song's bytes for the transient playback cache (`.engine` only). |
| `setStarred`, `reportPlayed` | Favorites and play reports, when the capabilities list them. |
| `waitingUntil`, `stop()` | Until when the server asked to wait, and stopping everything in flight when the switch goes off. |

A provider is registered with `StreamingCore` as a `ProviderDescriptor`, which says what it is before one is made. The core makes it only while its switch is on.

No provider for TIDAL, Qobuz, Apple Music, Spotify, Amazon Music or Deezer exists, and none can be added without an agreement with that service that an open-source player can honour.
