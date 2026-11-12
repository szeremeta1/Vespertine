# DoP auto-setup

USB DACs never say whether they decode DSD over PCM (DoP), and a DAC that doesn't decode it plays the stream as noise. So DoP stays opt-in, with three helpers that make the opt-in easier without guessing.

## 1. The known-DAC list

`Packages/VespertineKit/Sources/VespertineAudio/Resources/dop-dacs.json`, read as `DoPDACList.bundled`. A DAC on it has DoP on from the first launch (the DoP switch in the output popover still turns it off, and an off is remembered).

- **Matching** uses the USB vendor and product ID where macOS gives them (read from the I/O Registry, `USBIdentity`), or the vendor and model names in the Core Audio UID (`AppleUSBAudioEngine:<vendor>:<model>:<serial>:<n>`). The serial and the port number are never looked at.
- **Every entry carries a `source`**: an https link to where the claim comes from (the maker's spec page, a device report, this repository's [device notes](DEVICES.md)), with a few words on what it shows, and an `evidence` of `hardware`, `owner-report` or `manufacturer`. A test fails for an entry with no source, no `https`, or nothing to match on. No source, no entry.
- **`makers`** lists makers known for DSD DACs. It is only a hint: a DAC from a listed maker that isn't in `dacs` is *suggested* the test (part 3), never switched on.

### Adding a DAC

1. Get a source that says the DAC decodes DoP on a Mac: a maker's manual or spec page that says "DoP", or a report from the DAC's owner that DSD played natively once DoP was on (a [device report](https://github.com/szeremeta1/Vespertine/issues/new?template=dac_report.yml) is the right place for it).
2. Read its Core Audio UID (`defaults read org.szeremeta.Vespertine dopDeviceUIDs` after turning DoP on for it) for the vendor and model names, and its USB ID from System Information › USB if you want to match by that too.
3. Add the entry with its `source`, raise `revision`, run `swift test --filter DoP` in `Packages/VespertineKit`.

### The online update (optional)

On by default; **Settings › Updates › Update the list of DoP DACs** turns it off (a list fetched and verified earlier is still used). At launch, and at most once a day, the app fetches `dop-dacs.json` and `dop-dacs.json.sig` from the assets of the latest GitHub release (the place the Sparkle appcast lives). The list is used only if

- its signature is a valid Ed25519 signature of the exact file bytes under the key the app is already pinned to for updates (`SUPublicEDKey`), so Sparkle's `sign_update` can sign it; and
- its `revision` is higher than the bundled one's, and its `schema` is one this build reads.

Entries from it are added to the bundled ones (same `id` replaces), and its `revoked` ids are removed. The cache (`~/Library/Application Support/Vespertine/DoP/`) is checked again on every read. Offline, unsigned, tampered, older, or a 404 because no release carries the files yet: the bundled list stays, silently. Nothing waits for the network and playback never depends on it. The request is a plain GET; it sends nothing about the user or the Mac.

To publish an update (a maintainer step that is not automated here): edit the list, raise `revision`, sign it (`sign_update dop-dacs.json`, put the printed signature in `dop-dacs.json.sig`), and attach both files to the release.

## 2. The first-DSD test

For a USB or Thunderbolt DAC that isn't on the list, offers the 176.4 kHz DoP carrier, and has just had DSD converted to PCM, the inspector shows a card under the signal path with a **Test** button. The test:

1. stops playback and opens the output on its own engine, forced to DoP for this output only, with no EQ, room correction, Spatialize or transitions in the chain;
2. lowers the DAC's own hardware volume to a cap (and puts it back afterwards) if the DAC has a volume control and is above it. The cap is clamped to an absolute ceiling nothing can raise;
3. plays a five-second DSD64 clip made in code: a soft arpeggio that rises from silence over 1.5 s (in the DSD itself, since DoP can't be faded digitally) and falls away at the end;
4. watches the audio device list and the default output, and **ends the test and saves nothing on any change**;
5. checks the engine really planned DoP (if it planned PCM, nothing is saved: a PCM tone answered "music" must never turn DoP on);
6. asks **music or hiss?** and saves the answer per device UID in the same two lists the DoP switch uses (`dopDeviceUIDs` for music, `dopOffDeviceUIDs` for hiss), so it behaves exactly like flipping the switch.

How loud a DAC that doesn't decode DoP can be: DoP frames put an 8-bit marker above the 16 DSD bits, so read as 24-bit PCM the stream is an inaudible 88.2 kHz square wave plus noise in the low 16 bits. A test renders the clip, reads it that way, filters to the audible band (20 kHz) and checks the level stays under `DoPTestConstants.maxMisreadAudibleDBFS` (measured: about -62 dBFS RMS, bound -45). The DAC's own amplifier gain is not something the app can know, which is why the hardware-volume cap exists too, and why a DAC with no volume control relies on the clip's low level alone.

Every number and word of the test is in `DoPTestConstants.swift`. The words are localized in `App/Resources/Localizable.xcstrings`.

## 3. The hint

An unknown DAC that offers 176.4 kHz or more and whose maker is on `makers` gets the card's text changed from a plain offer to "<maker> makes DACs that play DSD, so this one may take DoP", with the same test button. DSD still converts to PCM until the user taps it; nothing is switched on silently.

## What was not verified

Written without a USB DAC attached: the I/O Registry lookup of USB IDs (`USBIdentity`), the engine playing the clip to a real DAC, the hardware-volume cap on real DACs, and the sheet's behaviour in the running app were not exercised. Name matching, the list, signatures, the cache, the hint rules, the answer's persistence, the cap, the fade-in and the misread-level bound are unit-tested.
