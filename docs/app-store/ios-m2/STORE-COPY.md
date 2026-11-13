# Vespertine Remote: App Store copy (draft)

Draft for Alex. Nothing has been entered in App Store Connect. No em dashes.

**Style source.** Matched to the live listings of Alex's other apps, read 2026-11-13: HuskyHowl ([App Store](https://apps.apple.com/us/app/huskyhowl/id6760141443), subtitle "Northeastern Sports Tracker") and Baba ([App Store](https://apps.apple.com/us/app/baba-all-things-ukraine/id6761655787), subtitle "News, Culture and Religion"). Both use a short plain noun-phrase subtitle, a one-paragraph opener, then ALL-CAPS section labels each followed by short, direct sentences, and close with short privacy fragments ("No user accounts. No tracking. No advertising." in Baba). Neither shows promotional text. Read through a fetch summary, not copied verbatim.

**Claims checked against the code** (`RemoteApp/Sources`): seek, shuffle, repeat and volume (NowPlayingView), turning record with Reduce Motion respected (VinylView), search, favorites, grid/Cover Flow, play/shuffle album (LibraryView, CoverFlowView), reorder/remove/clear queue (QueueView), keyboard shortcuts 1 to 4, P, Cmd-Option-arrows (RemoteView), GPL licence (LICENSE), no analytics in the app (docs/analytics.md).

**Claims still to confirm before submission:** the VPN/Tailscale sentence (needs a real connection test and the Mac port caveat from milestone 1); keyboard control and window resizing were not tried with a hardware keyboard or a real Split View window (see RESULT2.md).

## Name (17/30)
Vespertine Remote

## Subtitle (28/30)
Remote for Vespertine on Mac

Alternative (30/30): Your Mac library, within reach

## Promotional text (134/170)
Browse your Vespertine library, pick what plays next and choose the output, from your iPhone or iPad. Requires Vespertine on your Mac.

## Description (1573/4000)
Control Vespertine on your Mac from your iPhone or iPad. Browse your library, choose what plays next and pick the output from anywhere in the room.

NOW PLAYING
The cover or a turning record, with play, pause, skip, seek, shuffle, repeat and volume. Format, sample rate and the output in use, as Vespertine on the Mac reports them.

LIBRARY
Albums, artists, playlists and favorites. Search songs, artists and albums. Browse albums in a grid or in Cover Flow, and play or shuffle a whole record.

QUEUE
See what is playing and what comes next. Reorder it, remove songs or clear it.

OUTPUT
Choose where the Mac plays: its speakers, a USB DAC, a receiver or a speaker group.

BUILT FOR IPAD
A sidebar keeps Now Playing, the library, the queue and the output one tap away. Layouts adapt to portrait, landscape and the size of the window. Keyboard shortcuts switch sections and control playback.

PAIRING
Pair once with a code shown by Vespertine on your Mac. The connection is encrypted. At home the remote finds the Mac on your network. Away from it, a saved address reaches a paired Mac through your own VPN, including Tailscale, when the Mac is awake.

TRY IT WITHOUT A MAC
The built-in demo opens a made-up library with every screen of the remote. The demo does not play audio.

Light and dark appearances follow your device. Motion follows your accessibility settings.

Vespertine Remote controls playback on the Mac. It does not play music on this device. Requires Vespertine for Mac, free from vespertineapp.com.

Free and open source. No accounts. No ads. No tracking.

## Keywords (98/100)
music,mac,controller,library,albums,queue,player,hi-res,lossless,flac,dac,surround,ipad,cover flow

("remote" and "vespertine" are left out because the name is already indexed.)

## What's New (131/4000)
A sidebar on iPad, layouts that adapt as you resize the window, keyboard shortcuts, light and dark appearances, and a new app icon.

## Screenshot headlines (see screenshots/)

Store set: **dark only** (Alex, 2026-11-13). Six screenshots each for iPhone 6.9-inch and iPad 13-inch, captured from the built-in demo with `-VTScreenshot YES`, which hides the "Demo: a made-up library" bar. No light-appearance set is planned. The app itself still follows the device's light or dark setting.
- 01-now-playing: Your music. Your Mac. (NOW PLAYING); alternative: See what's playing.
- 02-library: Keep your library close. (ALBUMS, ARTISTS, PLAYLISTS); alternative: Browse the collection.
- 03-queue: Choose what comes next. (THE MAC'S QUEUE); alternative: Keep the queue in reach.
- 04-output: Choose where it plays. (OUTPUT ON YOUR MAC); alternative: Your Mac. Your speakers.
- 05-connection: A familiar connection. (PAIR ONCE WITH YOUR MAC); alternative: Connect to your Mac.
- 06-cover-flow: Browse by the covers. (GRID OR COVER FLOW); alternative: A different view of the collection.

## App Review notes
This is a remote for the open-source Vespertine Mac app. No account is required. Without a Mac, open the app and tap Try the Demo on the Macs screen. The demo shows a generated library and every main remote screen. It does not play audio. Music playback happens on the paired Mac. Local Network access discovers Macs; camera access is used only to scan a pairing code.
