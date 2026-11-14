# iPhone and iPad audio bench

What has been heard and measured on real hardware, and the scripts for doing it. Each script takes five minutes or less.
**Until a row below says "passed" with a date, a device and a build, the app makes no claim about it**: not bit-perfect output,
not head tracking, not gapless playback on a DAC.

Everything in the app up to here was built against tests that render offline (no sound device): 265 package tests cover the queue,
the stream channel, reconnection, the decoder's channel routing, the surround mixer's wiring and the kept-songs store. They show
the code does what it says; they can't show what an iPhone, AirPods Max or a USB DAC do with it.

## Results

| # | What | Result | Date | Device, iOS, build | Notes |
|---|---|---|---|---|---|
| B1 | Stereo to the speaker and to AirPods | not run | | | |
| B2 | Lock screen, Control Center, calls and Siri | not run | | | |
| B3 | Gapless album | not run | | | |
| B4 | 5.1 and 7.1 on AirPods Max: Fixed, Head Tracked, Off | not run | | | |
| B5 | Spatial double-processing check | not run | | | |
| B6 | DSD 5.1 from the Mac | not run | | | |
| B7 | USB DAC: rates and the label | not run | | | |
| B8 | USB DAC: bit-exactness (needs a loopback or a DAC with a bit-perfect light) | not run | | | |
| B9 | Away from home: Tailscale on cellular | not run | | | |
| B10 | Wi-Fi to cellular handover, Mac restart | not run | | | |
| B11 | Keep on This Device, airplane mode | not run | | | |
| B12 | The demo plays | not run | | | |

## Before any script

1. Mac: Vespertine from this branch, Settings › Remote: "Let phones control Vespertine" on, **Stream to Phones** on, the phone's
   "May play songs from this Mac" ticked.
2. Phone: the TestFlight build named in the row, paired with the Mac. Output › **This iPhone**.
3. Have on the Mac: one 16/44.1 FLAC album that runs without gaps (a live album), one 24/96 or 24/192 stereo album, one 5.1 FLAC,
   one 7.1 FLAC, one DSD 5.1 (DSF or SACD ISO), and a channel-identification file (a voice naming each speaker).

## B1. Stereo (2 min)

1. Play the 16/44.1 album on the phone's speaker. Expect sound within about two seconds, the badge **ORIGINAL FILE**.
2. Connect AirPods. Expect a pause when they connect or disconnect mid-song (the system's rule), and the output line naming them.
3. Seek to the middle and near the end. Expect sound within a second each time.

## B2. System behaviour (4 min)

1. Lock the phone while it plays. Expect the cover, title and a working scrubber on the lock screen; play, pause, next, previous work.
2. Call the phone (or start a Siri request). Expect the music to stop, and to come back when the call ends.
3. Pull the headphones out (or disconnect the AirPods). Expect a pause, never sound from the speaker.
4. Background the app for five minutes with music playing. Expect no dropout and the next song to start.

## B3. Gapless (3 min)

1. Play the live album from its first song; jump to ten seconds before the end of song 1.
2. Expect no silence and no click into song 2. Repeat for songs 2 to 3 with the phone locked.
3. Repeat once on the USB DAC (B7's setup).

## B4. Surround on AirPods Max (5 min)

1. AirPods Max on, Output › Surround on Headphones: **Head Tracked**. Play the channel-identification file (5.1, then 7.1).
2. Each voice should come from its speaker's direction: left surround behind-left, and so on. LFE is heard, not placed.
3. Turn your head: the scene should stay put. Badge: **SPATIAL AUDIO · HEAD TRACKED**.
4. Choose **Fixed**: the scene turns with your head. Badge: **SPATIAL AUDIO · FIXED**.
5. Choose **Off**: every voice is still heard, in plain stereo. Badge: **SURROUND FOLDED TO STEREO**.
6. On the phone's own speaker and over AirPlay: every voice heard, folded to stereo.

## B5. Double processing (3 min)

With B4 step 1 playing, open Control Center, long-press the volume slider. Note what the Spatial Audio button offers (Off / Fixed /
Head Tracked, or "Spatialize Stereo") and whether the app's sound changes when it is switched. If the system spatializes what the app
already rendered, the sound becomes diffuse and echoey: record which combination does it. This decides whether the app's own
renderer or the system's stays the default (open question Q3).

## B6. DSD 5.1 (3 min)

Play a DSD 5.1 song. Expect "The Mac is converting…" for a while the first time (note how long), then sound, badge **CONVERTED ON THE
MAC**, all six channels placed as in B4. Play it again: it should start at once (the Mac kept the conversion).

## B7. USB DAC rates (5 min)

1. Connect the DAC (USB-C, or the Camera Adapter). Output line names it.
2. Play 16/44.1, then 24/96, then 24/192. For each, note the rate the DAC's own display shows and the rate the app shows.
3. Expect the app to ask iOS for the song's rate. If the DAC's display doesn't follow, the app must say **resampled by iOS**; if the
   app says the rates match while the DAC shows another, that is a bug.
4. Open Output while each plays. "What Reaches the Output" must agree with the DAC's display: the rate, the channel count, and
   Resampled by iOS (No when the rates match). Note any row that disagrees.
5. Play 24/352.8 or DSD-converted material on a DAC that stops at 192: expect the output at 176.4, not 48.
6. Turn the phone's volume down: the signal chip must add "volume 80%" (or whatever it is). At 100% it says nothing.
7. Multichannel interface or HDMI receiver, if there is one: play a 5.1 song. Expect **SURROUND ON 6 OUTPUTS** and each channel on
   its own output (L, R, C, LFE, then the back pair). On a stereo DAC the same song is folded to stereo.
8. Unplug the DAC mid-song: expect a pause, and silence from the phone's speaker. Plug it back in: still paused until Play.

## B8. Bit-exactness (when a way to measure exists)

Needs a DAC with a bit-perfect indicator (or a digital loopback into a recorder) and the test files in `docs/fixtures`. Until this is
run, the phone shows no "bit-perfect" badge anywhere, and must not.

## B9. Away from home (5 min, plus a 30 min listen)

1. Tailscale on both. Pair at home on Wi-Fi first and type nothing: the Connection screen should list the Mac's addresses, one of them
   Tailscale. Then phone on cellular, Wi-Fi off. Expect it to reconnect by itself and Now Playing to say "Tailscale".
2. Play 24/192 FLAC, 24/96 stereo, then the DSD 5.1. Note time to first sound, and any dropout over 30 minutes.
3. Settings › Play over Cellular Data off: the next song must not start, and the reason is shown. On again: it plays.
4. Settings shows how much was fetched from the Mac.

## B10. Handover and restart (4 min)

1. While a song plays on Wi-Fi (with Tailscale available), turn Wi-Fi off. Expect the song to carry on from the buffer, "Waiting for
   the Mac" if it runs dry, then the same song continuing, without starting over.
2. Quit and reopen Vespertine on the Mac mid-song. Expect the same, with no new pairing.
3. Note how many seconds each took to resume, and whether the route shown changed (Home network, Tailscale).
4. Tailscale off on the phone, away from home: expect "Turn on Tailscale" wording, not a bare failure. Mac asleep: expect "not answering".

## B11. Keep on This Device (5 min)

1. Open an album, tap the keep button (arrow in a circle). Watch it in Library › On This Device until it says all songs.
2. Airplane mode on. Open On This Device, play the album. Expect sound, the cover, the lock screen, next and previous.
3. Airplane mode off. On the Mac, add a song to a kept playlist. Reconnect the phone: the playlist's page should show the new song
   and fetch it.
4. Remove the album (the menu on its page). Settings › iPhone Storage should show the room given back.

## B12. The demo (1 min)

Macs › Try the Demo. Output › This iPhone. Play any album: soft generated notes play, the lock screen works, next and previous work.
