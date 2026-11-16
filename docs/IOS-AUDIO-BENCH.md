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
| B8 | USB DAC: DSD as DoP, and bit-exactness | not run | | | |
| B9 | Away from home: Tailscale on cellular | not run | | | |
| B10 | Wi-Fi to cellular handover, Mac restart | not run | | | |
| B11 | Keep on This Device, airplane mode | not run | | | |
| B12 | The demo plays | not run | | | |
| B13 | The queue comes back after the app is closed | not run | | | |

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
5. On the last song of the queue with Repeat off, the lock screen's Next button is greyed out; Previous still restarts the song.
   Turn Repeat All on in the app: Next lights up and goes to the first song. Add a song with Add to Queue instead: Next lights up.
6. With nothing playing (a fresh launch, before any song), the headphones' play button does nothing and nothing appears on the
   lock screen.
7. Where the system shows it (CarPlay, some Bluetooth displays): the song's number in the queue, such as 3 of 12, and it follows
   Play Next and removals.

## B3. Gapless (3 min)

1. Play the live album from its first song; jump to ten seconds before the end of song 1.
2. Expect no silence and no click into song 2. Repeat for songs 2 to 3 with the phone locked.
3. Repeat once on the USB DAC (B7's setup).
4. Repeat: One Song on a song of the live album, ten seconds before its end: it goes round into its own start with no silence and
   no click, and Now Playing stays on that song with the scrubber back at 0:00.
5. On Tailscale over cellular (B9's setup), jump to ten seconds before the end of a song. Whether the next song joins without a
   gap depends on it arriving in time: note which happened. If it didn't arrive, expect a short wait and then the next song from
   its first note, never a skipped song.

## B4. Surround on AirPods Max (5 min)

0. On a fresh install (or after deleting the app), Output › Surround on Headphones reads **Off**, and a 5.1 song shows the badge
   **SURROUND FOLDED TO STEREO**: the spatial rendering is asked for, never the starting point. A choice made in an earlier build
   is kept. On iOS 17 the picker offers Off and Fixed only (the mixer can't follow the head before iOS 18).
1. AirPods Max on, Output › Surround on Headphones: **Head Tracked**. Play the channel-identification file (5.1, then 7.1).
2. Each voice should come from its speaker's direction: left surround behind-left, and so on. LFE is heard, not placed.
3. Turn your head: the scene should stay put. Badge: **SPATIAL AUDIO · HEAD TRACKED**.
4. Choose **Fixed**: the scene turns with your head. Badge: **SPATIAL AUDIO · FIXED**.
5. Choose **Off**: every voice is still heard, in plain stereo. Badge: **SURROUND FOLDED TO STEREO**.
6. On the phone's own speaker and over AirPlay: every voice heard, folded to stereo.
7. With Head Tracked chosen, open Control Center, long-press the volume slider and turn the AirPods' Spatial Audio off, then on.
   Output › What Reaches the Output › **Surround on Headphones** and the badge should follow: Fixed while it is off, Head Tracked
   again when it is on, without changing songs.
8. A stereo album and (on a DAC that passed the DoP test) a DSD album, with Head Tracked still chosen: badges **ORIGINAL FILE** and
   **NATIVE DSD · DoP**, never a SPATIAL AUDIO badge. Two-channel songs don't go through the spatial mixer whatever is chosen.

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

## B8. DSD as DoP, and bit-exactness (10 min)

Needs a DAC that shows what it is receiving (a DSD light or a display). Volume at 100% on the phone; turn the amplifier or the DAC's own
knob down first.

1. With the DAC never tested: play a DSD64 song. Expect **CONVERTED ON THE MAC** and PCM on the DAC's display. Nowhere "DoP".
2. Output › Play DSD natively? › Test DoP. Expect the music to stop, about five seconds of a soft chord, then "Did you hear music or
   hiss?". Note what the DAC's display showed during the sound (DSD64, or PCM 176.4), and what you heard.
3. Answer what you heard. After Music: play the DSD64 song again. Expect **NATIVE DSD · DoP**, the DAC showing DSD64, Output showing
   Song DSD64, DoP 176.4 kHz, Output runs at 176.4 kHz, Resampled by iOS No. Any hiss or noise at any point is a FAIL: note when.
4. Let two DSD64 songs of one album play through: no click, no burst of noise and no drop out of DSD between them.
5. Seek, pause and resume in a DSD song: note any click or noise.
6. Turn the phone's volume down one step mid-song: expect a short gap, then the song carrying on from the same place as PCM
   (**CONVERTED ON THE MAC**, the chip showing the volume). Never noise. Back at 100%, the next DSD song is DoP again.
7. Play a DSD128 song on a DAC that stops at 192 kHz: expect PCM (the carrier would be 352.8), with no noise before it starts.
8. Unplug the DAC mid-DSD-song: a pause, silence from the speaker. Plug another DAC in: it is not sent DoP until it passes its own test.
9. On a DAC that does not take DoP: run the test, expect a quiet hiss or silence, answer Hiss. DSD stays PCM; "DoP stays off for this DAC."
10. Test with the volume below 100%: expect "The test needs the volume at 100%." and no sound.
11. From an SMB share, no Mac involved (Your Shares): play a DSD64 `.dsf` or `.dff` on the DAC that passed. Expect **NATIVE DSD · DoP**
    and the DAC showing DSD64. Unplug the DAC and play it on the phone's speaker: expect **CONVERTED ON THIS DEVICE**, clean sound at a
    normal level, and seeking that lands where asked. Any hiss or noise is a FAIL.

Bit-exactness of PCM is a separate measurement (a DAC with a bit-perfect light, or a digital loopback into a recorder, and the files in
`docs/fixtures`). A DAC playing the DoP test as music has received those frames exactly, at 176.4 kHz and 100% volume; that says
nothing about other rates or volumes. Until PCM is measured, the phone shows no "bit-perfect" badge anywhere, and must not.

## B9. Away from home (5 min, plus a 30 min listen)

1. Tailscale on both. Pair at home on Wi-Fi first and type nothing: the Connection screen should list the Mac's addresses, one of them
   Tailscale. Then phone on cellular, Wi-Fi off. Expect it to reconnect by itself and Now Playing to say "Tailscale".
2. Play over Cellular Data is off on a fresh install: a song must not start, and the reason is shown. Turn it on in Settings: it plays.
3. Play 24/192 FLAC, 24/96 stereo, then the DSD 5.1. Note time to first sound, and any dropout over 30 minutes.
4. Settings shows how much was fetched from the Mac.

## B10. Handover and restart (4 min)

1. With Play over Cellular Data on, while a song plays on Wi-Fi (with Tailscale available), turn Wi-Fi off. Expect the song to
   carry on from the buffer, "Waiting for the Mac" if it runs dry, then the same song continuing, without starting over.
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

## B13. The queue comes back (3 min)

1. Play an album from its third song, add two songs with Play Next, turn Repeat All on, seek to about 1:00 and pause.
2. Swipe the app away in the app switcher and open it again. Expect Now Playing to show the same song, paused at about 1:00, and
   the Queue to show the same Playing Next and Up Next, with Repeat All still on. Nothing plays by itself.
3. Tap Play: it starts from about 1:00, not from the start of the song.
4. Play, and swipe the app away mid-song without pausing. Reopen: the same song, paused within about ten seconds of where it was.
5. Reopen with the Mac asleep or out of reach: the queue is shown once the Mac connects, or at once when songs from it are kept
   on this device (those play; the others say the Mac isn't answering). Note what you see.
6. Choose another Mac (or a share), play something there, and go back to the first: each has its own queue. The demo starts empty
   every time. Forgetting a Mac in Macs removes its queue.
