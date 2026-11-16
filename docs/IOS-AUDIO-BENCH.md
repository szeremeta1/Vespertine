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
| B14 | Music on the phone: a folder from Files, iCloud Drive, a USB drive | not run | | | |
| B15 | ReplayGain: off by default, on, and never on DoP | not run | | | |
| M1 | Measured by the app: MP3, AAC and FLAC joins, and what ReplayGain does to the level | not run | | | |

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
6. Repeat steps 1 and 2 with a gapless album in MP3 and one in AAC (a live album or a continuous mix, ripped as it was sold): no
   silence and no click between songs. The package tests show the delay and padding are left out to the frame; this step is the
   same thing heard on real albums.
   Without a listener: M1 measures the same joins on the phone.

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
   hiss?" with "176.4 kHz" under it. Note what the DAC's display showed during the sound (DSD64, or PCM 176.4), and what you heard.
3. Answer what you heard. After Music the same chord follows at 192, 352.8 and 384 kHz, with the same question and the rate under it
   each time. For each rate note what the DAC's display showed (DSD64 for 176.4 and 192, DSD128 for 352.8 and 384) and answer what you
   heard. A rate the DAC won't run at is skipped without a question. When it ends, the section lists "DoP passed at" and, if any,
   "DoP not passed at", and they must match what the display showed. Write the four results in the table under these steps.
   Then: play the DSD64 song again. Expect **NATIVE DSD · DoP**, the DAC showing DSD64, Output showing
   Song DSD64, DoP 176.4 kHz, Output runs at 176.4 kHz, Resampled by iOS No. Any hiss or noise at any point is a FAIL: note when.
4. Let two DSD64 songs of one album play through: no click, no burst of noise and no drop out of DSD between them.
5. Seek, pause and resume in a DSD song: note any click or noise.
6. Turn the phone's volume down one step mid-song: expect a short gap, then the song carrying on from the same place as PCM
   (**CONVERTED ON THE MAC**, the chip showing the volume). Never noise. Back at 100%, the next DSD song is DoP again.
7. Play a DSD128 song on a DAC that stops at 192 kHz: expect PCM (the carrier would be 352.8), with no noise before it starts.
8. Unplug the DAC mid-DSD-song: a pause, silence from the speaker. Plug another DAC in: it is not sent DoP until it passes its own test.
9. On a DAC that does not take DoP: run the test, expect a quiet hiss or silence, answer Hiss. DSD stays PCM; "DoP stays off for this DAC."
10. Test with the volume below 100%: expect "The test needs the volume at 100%." and no sound.
11. On a DAC that passed at 176.4 or 192 kHz, volume at 100%: play a lossless stereo album at that rate (24/176.4 or 24/192). Expect the
    badge **ORIGINAL FILE · VERIFIED ON THIS DAC**, and in Output the rows "Original file: Verified on this DAC" and "DoP passed at".
    Play a 16/44.1 or 24/96 album: expect **ORIGINAL FILE · NO PROCESSING** (no DoP test reaches those rates).
12. With either of those badges showing, each of these must bring back plain **ORIGINAL FILE** within a second or so: one step down
    on the phone's volume; unplugging the DAC so the speaker or AirPods take over; a song at a rate the DAC won't run at (Resampled by
    iOS: Yes). Back at 100% on the DAC at the song's rate, the stronger badge returns.

| DAC | 176.4 kHz | 192 kHz | 352.8 kHz | 384 kHz | Date, device, iOS, build |
|---|---|---|---|---|---|
| | | | | | |

Bit-exactness of PCM is a separate measurement (a DAC with a bit-perfect light, or a digital loopback into a recorder, and the files in
`docs/fixtures`). A DAC playing the DoP test as music has received those frames exactly, at that rate and 100% volume; that says
nothing about other rates or volumes, and DoP has no rate below 176.4 kHz. So **VERIFIED ON THIS DAC** appears only for a song at a
rate that DAC passed at, with nothing known to change its samples. Until PCM is measured, the phone shows no "bit-perfect" badge
anywhere, and must not.

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

## B14. Music on the phone (8 min)

No Mac is needed. Have a folder of a few albums (one that runs without gaps) in three places: on the phone (Files › On My iPhone),
in iCloud Drive, and on a USB drive with an adapter for the phone.

1. Macs › **Add a Folder from Files**, choose the folder on the phone. Expect it under Your Folders, its albums and covers listed,
   and a song to play. Output shows the folder, its count of songs and when it was last scanned.
2. Play the gapless album across two songs: no gap, no click.
3. Swipe the app away and open it again: the folder opens by itself, with its queue, and plays. Nothing asks for the folder again.
4. In Files, delete one song and rename another. Back in the app: the deleted song is gone from its album and the renamed one is
   there under its new name, without tapping Scan Again.
5. The same with the folder in iCloud Drive. Note whether songs that aren't downloaded are listed, and whether playing one
   downloads it (this has not been seen on a real phone; write down what happens).
6. The same with the folder on the USB drive. Mid-song, pull the drive out: the song stops and the app says the folder can't be
   found and to plug the drive in. Plug it in, tap Try Again: the songs play again.
7. In Files, long-press a FLAC or MP3 anywhere › Share › Vespertine (or Open in Vespertine). Expect the app to open **Opened
   Files** and play it. In Files › On My iPhone › Vespertine the copy is there; delete it and it leaves the app's list.
8. Open a file the phone can't play by itself (a `.dsf`): an alert says so, and nothing is added.

## B15. ReplayGain (4 min)

Needs an album whose files carry ReplayGain tags (most taggers can write them) and one song without them. Note each song's track
and album gain from the tagger first.

1. Output › This iPhone. Expect ReplayGain to say Off on a fresh install, and "What Reaches the Output" to have no ReplayGain row.
2. Play a tagged song and choose Track. Expect the level to change at once without the song starting over, and a row
   `ReplayGain` with the song's gain to one decimal place, such as `−6.2 dB`. Compare with the track gain the tagger shows for it.
3. Choose Album: the row changes to the album's gain. Let the album run into its next song: no gap, no click, the row follows the song.
4. Play the song without tags: the row says "None for this song" and it plays at its own level.
5. On the USB DAC with a DSD song playing as NATIVE DSD · DoP (B8's setup): turn ReplayGain on. Expect the DSD light on the DAC to
   stay on and the row to say "None for this song".
6. Choose Off: the row goes. Close the app and open it again: the choice made last is still the one shown.
7. Keep a tagged album on this device (B11's setup), turn the Mac off, and play it with Track chosen: the row shows the same gain as in step 2.
8. On a share (if one is set up): a tagged FLAC, MP3 and M4A each show their gain in the row.
   Without a listener: M1 measures steps 2 and 3's levels on the phone (not the DoP step, which needs the DAC).

## M1. Measured without a listener (5 min, nobody touches the phone)

For the Mac the phone is plugged into: no ear, no microphone and no recording. A debug build of the app plays test songs
through its own player, the way it plays a folder chosen in Files, keeps what the player hands to iOS (a tap on the
engine's mixer, after decoding, the join between songs, ReplayGain and the mixer's conversion to the output's rate) and
measures it. What iOS, a Bluetooth link or a DAC do after that isn't in the capture, so this stands in for B3 step 6 and
B15 steps 2 and 3 as far as the app's own output goes, and no further. The sound does come out of the phone while it runs.

The test songs are one 1 kHz tone cut into songs, so a join played right is one unbroken tone:

```sh
docs/fixtures/make-phone-bench-fixtures.sh /tmp/vtbench-music     # needs ffmpeg with libmp3lame
```

Any folder of albums laid out the same way does as well (a folder for each album, songs in the order of their names).
Songs whose files carry ReplayGain values are measured for level and not for joins; they need seven seconds of steady tone.

1. Install a **Debug** build on the phone (the bench isn't in Release builds) and unlock the phone.
2. Find the phone and the app: `xcrun devicectl list devices`, and the bundle id the build was installed under.
3. Put the songs in the app's folder:
   `xcrun devicectl device copy to --device <phone> --domain-type appDataContainer --domain-identifier <bundle id> --source /tmp/vtbench-music --destination Library/VTBench/music`
4. Run it and read the report as it is printed (the command returns when the app quits, after about two minutes):
   `xcrun devicectl device process launch --device <phone> --console --terminate-existing <bundle id> -VTBench YES`
5. The same report as JSON, and each capture as a WAV file, are on the phone in `Library/VTBench/results`:
   `xcrun devicectl device copy from --device <phone> --domain-type appDataContainer --domain-identifier <bundle id> --source Library/VTBench/results --destination ./vtbench-results`

What to expect, a line for each pair of neighbouring songs and each tagged song:

- `tone-flac`, `tone-mp3`, `tone-aac`: **GAPLESS**, gap 0.00 ms, slip within half a sample, level step within 0.2 dB.
- `gap-30-80`: **GAP** 30 ms, then **GAP** 80 ms (to a tenth of a millisecond). This is the control: it shows the meter
  reports a silence when there is one.
- `replaygain/tagged.flac` and `tagged.mp3`: **MATCHES**, Track measured −6.20 dB and Album −3.50 dB.
  `held.flac` asks for +9 dB with a peak that leaves room for +6.02 dB: **MATCHES** at +6.02 dB, "held by the peak".

How to read a join's numbers. *Gap*: the longest silence where the songs meet. *Slip*: how far the second song's tone is
out of step with the first's, in samples; a frame of encoder delay or padding left in, or a buffer dropped, shows here even
with no silence (it can't see a slip of a whole number of the tone's cycles, 44.1 samples for these songs). *Level step*:
the change of level across the join. *Residual*: how rough the join is against the rest of the capture, in dB relative to
the tone. Between lossless songs the join must be as clean as the rest, or it is a **CLICK**. An MP3 or AAC song brings its
encoder's edge with it, each song having been encoded by itself (around −30 dB for these files, on any player), so a lossy
join is held to no silence, no slip and no level step, and its residual is given for the record. **INCONCLUSIVE** comes
with its reason: a silence away from the join (the song waited for its bytes) or a capture that skipped.

On a Mac, with no sound and no phone, the same bench runs over the same folder with the same decoders:
`VTBENCH_FOLDER=/tmp/vtbench-music swift test --package-path Packages/VespertineRemoteKit --filter aFolderNamedFromOutside`.
It says what the files themselves are good for before the phone is asked.
