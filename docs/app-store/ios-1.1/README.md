# Vespertine for iPhone and iPad 1.1 ("Play on this iPhone"): App Store kit, draft

Draft for Alex. **Nothing here has been entered in App Store Connect, and nothing is submitted for review without his go.**
Internal TestFlight builds are the only thing uploaded. The 1.0 kit (remote only) is in `../ios-m2`; this file lists what
changes when the app also plays music.

## What must be true before submission

- [ ] The bench scripts in `docs/IOS-AUDIO-BENCH.md` (B1 to B7, B9 to B12) pass on Alex's iPhone with the release build.
- [ ] Alex has chosen the wording below (three options each; the first is the recommendation).
- [ ] The player screenshots are captured (dark, the real app, the demo library, no real device names). Not captured yet:
      the capture rig needs a working iOS Simulator, which the build machine used for this work doesn't have.
- [ ] The App Store exception wording has had its review (open question Q12).
- [ ] Export compliance answer re-checked: the app uses only the system's TLS (`ITSAppUsesNonExemptEncryption` = NO).

## Copy that changes

The 1.0 description ends with "It does not play music on this device" and "The demo does not play audio". Both are now false.

**Subtitle (30 max)**

1. `Your Mac's music, here or there` (30) (recommended)
2. `Hi-res player and Mac remote` (28)
3. `Remote for Vespertine on Mac` (28, the 1.0 line; undersells the player)

**Promotional text (170 max)**

1. `Play your Mac's hi-res library on your iPhone, or control Vespertine on the Mac from across the room. Requires Vespertine on your Mac.` (133) (recommended)
2. `Your whole Vespertine library on your iPhone and iPad: play it here, or run the Mac from the sofa. Requires Vespertine on your Mac.`
3. Keep the 1.0 text.

**New description sections** (in the 1.0 voice; ALL-CAPS labels, short sentences)

PLAY ON THIS IPHONE
Choose This iPhone in Output and your Mac sends the music here: to the speaker, your headphones or a USB DAC. Lossless files
arrive as they are. Formats an iPhone can't open, like DSD, are converted to lossless FLAC on the Mac first. Playback continues
with the screen locked, with controls on the Lock Screen.

SURROUND ON HEADPHONES
5.1 and 7.1 albums are placed around you on headphones, fixed or following your head. *(Hold this section until bench B4 and B5
pass: it is a claim about what is heard.)*

KEEP IT WITH YOU
Keep albums and playlists on this device and play them without the Mac: on a plane, on the road. Choose how much room they may use.

AWAY FROM HOME
Reach your Mac over your own VPN, including Tailscale. Choose whether music may use cellular data, and see how much it used.

Replace the closing lines with: `The built-in demo opens a made-up library and plays sound the app makes itself.` and
`Requires Vespertine for Mac, free from vespertineapp.com.`

**What's New**

1. `Play your Mac's library on this iPhone or iPad: lossless, with the screen locked, on headphones or a USB DAC. Keep albums for when the Mac is away. Sort and filter albums, grouped search, add to playlists. Now in 44 languages.` (recommended)
2. A shorter one: `Vespertine now plays on your iPhone and iPad, not only on your Mac.`

Do not say "bit-perfect", "Spatial Audio" or "gapless on a DAC" anywhere in the listing until the matching bench row has passed.

## App Review notes (paste into "Notes" when submitting)

```
Vespertine is the companion to Vespertine for Mac (free, https://vespertineapp.com). It controls the Mac app and can play
the Mac's music library on the iPhone or iPad itself.

HOW TO TRY IT WITHOUT A MAC
1. Open the app. On the first screen tap "Try the Demo".
2. Open the Output tab and tap "This iPhone" (or "This iPad").
3. Open Library > Albums, open any album and tap Play. You will hear soft generated notes. The demo's library is made up
   and its sound is generated inside the app; there are no recordings in it.
4. Lock the device: playback continues and the Lock Screen shows the controls.

BACKGROUND AUDIO (UIBackgroundModes: audio)
The app plays music the user chose, from their own Mac or kept on the device, and keeps playing with the screen locked or
another app in front. Steps 2 to 4 above show it.

LOCAL NETWORK
The app finds the user's Mac with Bonjour (_vespertine._tcp) and connects only to Macs the user paired with a code shown on
the Mac. Nothing is sent anywhere else. There is no account and no server of ours.

CAMERA
Used only to scan the pairing QR code that Vespertine for Mac shows. The demo doesn't need it.

MOTION
Cover Flow reads the motion sensors while it is on screen to shift its perspective (Settings > "Tilt to Shift the
Perspective"). Nothing is recorded. It is off under Reduce Motion.

CELLULAR DATA
Music can come from the user's own Mac over their own VPN. Settings > "Play over Cellular Data" turns that off.

CONTENT
The app has no store, no catalog and no streaming service. All music is the user's own files on their own Mac.

LICENSE
GPL-3.0-or-later with an App Store exception (the text is in Settings > About and in the source repository).
```

## Privacy answers (App Store Connect › App Privacy)

Unchanged from 1.0: **Data Not Collected.** The app has no analytics, no accounts and no third-party SDKs. The privacy manifest
(`RemoteApp/Resources/PrivacyInfo.xcprivacy`) declares UserDefaults (CA92.1) only. The player adds files in Application Support
(kept songs, excluded from backup) and Caches (stream buffers, covers); neither uses a required-reason API (file sizes are
read, timestamps are not). If an upload comes back with ITMS-91053, add the API it names to the manifest.

## Version

`RemoteApp/project.yml` is at **1.0 (6)** on this branch: the marketing version stays 1.0 until the first store release, and each
TestFlight upload takes the next build number. The remote-only 1.0 (4) on TestFlight is untouched; whether that goes to the store
first, or the app with the player is the first store release (and under which version), is Alex's call (open question Q1). This
folder is named for the release the handoff calls 1.1.
