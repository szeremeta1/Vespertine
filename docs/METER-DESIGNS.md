# Meter designs: the research

The research behind the Meters visualizer's designs (see [VISUALIZER.md](VISUALIZER.md#meter-designs)): the standards that fix how the needles move, the real instruments the faces are modelled on, which of them made it in and why, and how telling left from right stays true to the standards. The reference photographs are on Wikimedia Commons, linked below.

## 1. The standards

### VU meter (ANSI C16.5-1942, IEC 60268-17)

The primary source is the paper that defined it: H. A. Chinn, D. K. Gannett and R. M. Morris, "A New Standard Volume Indicator and Reference Level", *Bell System Technical Journal* 19 (1940), pp. 94-137 ([PDF](https://bh.hallikainen.org/uploads/harold/NewStandardVolumeIndicatorAndReferenceLevel.pdf)). From its text:

- **Ballistics.** "the sudden application of a 1000-cycle sine wave of such amplitude as to give a steady deflection at the scale point where the instrument is to be read, shall cause the pointer to read 99 per cent of the final deflection in 0.3 second." "The movement shall be slightly less than critically damped, so that the pointer will overswing not less than 1 per cent nor more than 1.5 per cent." The underdamped needle "will pause for a moment and then start downward more slowly" when the tone stops (the same curve inverted). A full-wave rectifier, so either polarity reads the same.
- **Scale.** Two layouts: **Type A** "emphasizes the vu markings and has an inconspicuous voltage scale"; **Type B** reverses the emphasis (per cent on top). Main divisions and numerals black, secondary data smaller ("and in one case, are in red"). "The color of the scale card, which is a light orange-yellow" (83 % of 80+ broadcast technicians preferred it to white). The reference point sits at **71 %** of the scale length. "an arc to connect the lower extremities of the vertical black division marks". The scale "does not extend beyond the 100 per cent mark (except in the form of a red warning band)". Instrument cases: "matte finished ... such as light grey".
- 0 VU = +4 dBu (1.228 V across 600 Ω); a 200 µA d'Arsonval movement behind a copper-oxide full-wave rectifier ([Wikipedia: VU meter](https://en.wikipedia.org/wiki/VU_meter)). Scale -20 to +3 VU.
- A scale vs B scale in practice: A "for use on test equipment and limiters", B "for everyday program level monitoring" ([Radio World, "The VU meter legacy shines on"](https://www.radioworld.com/columns-and-views/the-vu-meter-legacy-shines-on)); Hoyt's catalogue: A has -20…+3 above the arc and 0-100 below ([Weschler/Hoyt VU meters](https://www.weschler.com/product/hoyt-vu-meters/)).

Vespertine's existing VU ballistics (damping 0.81, ω = 13.42 rad/s; 99 % in 300 ms, 1.3 % overshoot, tested) already implement this, and every new VU design uses them unchanged.

### Peak programme meter (IEC 60268-10)

From [Wikipedia: Peak programme meter](https://en.wikipedia.org/wiki/Peak_programme_meter) (its table follows IEC 60268-10; the standard itself is paywalled, [BSI listing](https://knowledge.bsigroup.com/products/sound-system-equipment-methods-for-specifying-and-measuring-the-characteristics-of-peak-programme-level-meters)):

| Type | Integration time | Return | Scale (as printed) | Alignment level | Permitted maximum |
|---|---|---|---|---|---|
| I, DIN | 5 ms | 20 dB in 1.7 ± 0.3 s | -50 -40 -30 -20 -10 -5 0 +5 dB | -9 | 0 |
| I, Nordic | 5 ms | 20 dB in 1.7 ± 0.3 s | -36 -30 -24 -18 -12 -6 TEST +6 +9 (+12) | TEST | +9 |
| IIa, BBC | 10 ms | 24 dB in 2.8 ± 0.3 s | 1 2 3 4 5 6 7 (4 dB a mark) | 4 | 6 |
| IIb, EBU | 10 ms | 24 dB in 2.8 ± 0.3 s | -12 -8 -4 TEST +4 +8 +12 | TEST | +9 |

- **Integration time** is defined by a 5 kHz tone burst that reads 2 dB under the steady tone.
- PPMs are usually **white on black** "to reduce eye strain"; the BBC meter (C. G. Mayo, in service 1938) had movements by **Ernest Turner**, later **Sifam** (Torquay), who ended the Type 74 twin movement in 2009 and all PPM movements in 2010.
- **Stereo twin-needle PPMs** (UK): two concentric needles, **red = A (left), green = B (right)**; the sum/difference version has **white = M, yellow = S**. M and S are normally aligned so M = A + B − 6 dB and S = A − B − 6 dB (the **M6** standard; BBC used M3 until 1999). Confirmed by a broadcast engineer on [uk.tech.broadcast](https://groups.google.com/g/uk.tech.broadcast/c/cd0Livuxv_Q) (last twin movements made by Sifam, Ernest Turner the first), and by Canford's Sifam 74B listing: twin movement, "BBC 1-7, white characters on black background" ([Canford](https://canford.co.uk/Products/85429/58-357)). Dual twin boxes with Sifam 74A/74B were sold for "monitoring left/right and sum/difference" (Alice, [product page](https://www.alice.co.uk/?p=761); not readable from here, quoted from the search summary).

## 2. The instruments looked at

Photographs (Wikimedia Commons; licences as marked there):

| Instrument | What it shows | Reference |
|---|---|---|
| Sifam Type 34A, BBC scale | Matt black face and bezel, white radial bars without an arc, numerals 1-7 upright above them, a short bar past 7, a white tapered needle whose pivot hides under the deep lower lip, slotted zero adjuster below the window, maker's mark bottom left | [Sifam.type34A.British.ppm.jpg](https://commons.wikimedia.org/wiki/File:Sifam.type34A.British.ppm.jpg) |
| Old BBC PPM | Round black flange, black face, white bars 1-7 | [Spliced.oldppm.jpg](https://commons.wikimedia.org/wiki/File:Spliced.oldppm.jpg) |
| BBC baptools PAQT meter | Twin needles, red A and green B, on the BBC scale | [Paqt_meter.ab.png](https://commons.wikimedia.org/wiki/File:Paqt_meter.ab.png), [m6](https://commons.wikimedia.org/wiki/File:Paqt_meter.m6.png) |
| IEC 60268-10 scale drawings | DIN, Nordic, BBC and EBU scales as bargraphs | [DIN](https://commons.wikimedia.org/wiki/File:PPM_IEC_268-10_I_DIN.jpg), [Nordic](https://commons.wikimedia.org/wiki/File:PPM_IEC_268-10_I_Nordic.jpg), [IIa](https://commons.wikimedia.org/wiki/File:PPM_IEC_268-10_IIa_British.jpg), [IIb](https://commons.wikimedia.org/wiki/File:PPM_IEC_268-10_IIb_EBU.jpg) |
| Siemens & Halske light-pointer instrument (1950) | Glossy black moulded case, white scale, per cent row above (0 .3 .5 1 2 3 5 10 20 30 35 50 100 180), dB row below (-50 … 0 +5), red cross at -9, red block from 0 to +5, a band of light | [Lichtzeiger Instrument Siemens & Halske.jpg](https://commons.wikimedia.org/wiki/File:Lichtzeiger_Instrument_Siemens_%26_Halske.jpg) |
| NTP 177-300 | Twin horizontal DIN bars on a black panel, mirrored scales, red -9 marks | [Aussteuerungsmessgerät NTP177-300.jpg](https://commons.wikimedia.org/wiki/File:Aussteuerungsmessger%C3%A4t_NTP177-300.jpg) |
| API console meter bridge | Bright yellow backlit rectangles, 20 10 7 5 3 2 1 0 1 2 3, red arc, "VU", channel legends under | [API Console - VU Meter Bridge](https://commons.wikimedia.org/wiki/File:API_Console_-_VU_Meter_Bridge,_API560_10_Band_EQ,_API550A_3_Band_EQ_(2017-01-05_19.45.22_piqsels.com_en).jpg) |
| TL Audio (Sifam) VU | Amber backlit, red band 0 to +3, "−" "+" at the ends, separate PEAK lamp | [VU meter & Peak lamp, TL Audio VTC](https://commons.wikimedia.org/wiki/File:VU_meter_%26_Peak_lamp,_TL_Audio_VTC,_Metway_Studios.jpg) |
| TEAC deck VU | Cream face, red band under 0-3, big "VU", PEAK LED on the face, pivot cap visible | [VU Meter.jpg](https://commons.wikimedia.org/wiki/File:VU_Meter.jpg) |
| Revox A77 | Two small backlit VU meters in an anthracite panel under a brushed aluminium strip, "CHANNEL I / II", wooden case | [Revox A77 MkIV.jpg](https://commons.wikimedia.org/wiki/File:Revox_A77_MkIV.jpg), [3501832489crop](https://commons.wikimedia.org/wiki/File:Revox_A77_tape_recorder_(3501832489crop).jpg) |
| Revox B77 | Orange-backlit VU faces, "LEFT/RIGHT CHANNEL" | [B77 VUMeter.png](https://commons.wikimedia.org/wiki/File:B77_VUMeter.png) |
| Marantz 5030 cassette deck | Brushed silver front, deep wells with mirrored walls, cream face, blue scale to +1 with per cent under it, red 0 to +6, "VU" at both ends, "dB", PEAK L R lamps under | [VU meters of Marantz 5030 cassette deck.jpg](https://commons.wikimedia.org/wiki/File:VU_meters_of_Marantz_5030_cassette_deck.jpg) |
| Studer A80 | Yellow backlit VU in each channel module | [Studer A80 - analog 8 track recorder.JPG](https://commons.wikimedia.org/wiki/File:Studer_A80_-_analog_8_track_recorder.JPG) |
| TEAC AR-60 | Black face, pale blue scale, red 0-3 | [TEAC A-6010 VU meters](https://commons.wikimedia.org/wiki/File:TEAC_A-6010_tape_recorder,_VU_meters_(16266947193).jpg) |
| McIntosh MC2105 | Black glass, green/blue lettering | [McIntosh MC2105 illumination](https://commons.wikimedia.org/wiki/File:McIntosh_MC2105_illumination,_Greenhouse_Studio,_Silver_Lake,_LA.jpg) |
| Nagra modulometer | Cream, dB and per cent, a different family (Swiss portable) | [NAGRA_Modulometer.jpg](https://commons.wikimedia.org/wiki/File:NAGRA_Modulometer.jpg) |

**Measured from the photos.** The DIN scale is neither linear in dB nor in voltage; it opens out toward the top. Measured across the scale (fraction of the way from -50 to +5 dB) on two different instruments: Siemens & Halske -40: 0.048, -30: 0.161, -20: 0.339, -10: 0.545, 0: 0.801; NTP 177-300 -40: 0.056, -30: 0.171, -20: 0.351, -10: 0.567, 0: 0.835. They agree within about 3 %; Vespertine uses their average. The Sifam 34A's marks span ±39.5° about upright (13.17° a mark), the needle rests at about -47° and the end bar sits at about +46°; the pivot is 1.22 window heights below the window's top.

## 3. Which designs, and why

Eleven sub-designs, the two originals included. Each one keeps its standard's ballistics; only the face, the case and (for PPMs) the IEC type change.

**VU (IEC 60268-17 ballistics, unchanged)**
1. **Original**: Vespertine's existing pair, untouched, still the default.
2. **Broadcast**: the 1940 standard itself, as the BSTJ paper describes it: a light orange-yellow Type A card (VU numerals black, per cent scale small under the arc, red warning band from 0 to +3), black moulded case with nickel screws, on a light grey hammer-finish panel (the paper's "light grey" case), engraved LEFT/RIGHT CHANNEL, with a centre-zero balance meter between the two (see section 4).
3. **Console**: studio meter bridge in the API/Sifam style: bright amber faces lit hard from behind, 20 … 3 with a red arc, thin glossy bezels, a dark slate-grey hammer-finish bridge with big L/R legends, blue names and PEAK lamps under each meter; balance meter between.
4. **Tape Recorder**: modelled on the Revox A77: two backlit cream meters side by side under chrome rims in an anthracite panel, a brushed aluminium strip across the top, CHANNEL I / CHANNEL II, in a teak case (the A77's wooden case).
5. **Cassette Deck**: modelled on the Marantz 5030: brushed silver front, deep wells with mirrored walls, cream face with the blue scale to +1 and the red one to +6, "VU" at both ends, "dB", PEAK L R lamps under a bracket, in a walnut case. Its +6 scale puts 0 VU at half the travel; the needle is the same VU movement (tested: 300 ms, 1-1.5 % overshoot).

**PPM (IEC 60268-10)**
6. **Original**: untouched (BBC scale, Type IIa).
7. **BBC** (Type IIa): two Sifam 34A-type meters, faithful to the photo (bars, numerals, short end bar, white needle, zero adjuster), on BBC-grey panel with red/green channel keys.
8. **BBC Stereo** (Type IIa): the BBC's twin-needle pair: left meter red A (left) and green B (right) on one pivot; right meter white M and yellow S, aligned M6 (M = (A+B)/2, S = (A−B)/2).
9. **EBU** (Type IIb): the same movement and case, marked -12 … TEST … +12 with 2 dB minor bars.
10. **DIN** (Type I): two Siemens & Halske light-pointer instruments in glossy black cases, standing on an oak desk: the band of lamp light runs across the white scale; the reference tone reads -9 (alignment level) and 0 is the permitted maximum.
11. **Nordic** (Type I): the Sifam case with the Nordic scale -36 … TEST … +12, 6 dB a mark.

**Left out, and why**
- **McIntosh blue meters**: they are output watt meters with "Dynamic Peak Locking" and a "time stretching" circuit (MC2105 manual, [manualmachine](https://manualmachine.com/mcintosh/mc2105/2058449-user-manual)), so they follow neither IEC 60268-17 nor 60268-10, and no published attack/hold/decay figures were found. Drawing one with VU ballistics would misrepresent it; the designs are meant to follow the IEC VU and PPM.
- **Marantz/Sansui/Pioneer receiver meters**: receivers carry signal-strength, tuning or watt meters rather than VU meters; the cassette deck covers that era's hi-fi look with real VU meters.
- **Studer A80, Ampex, Otari, Neve, SSL**: Studer's A80 VU module and Neve/SSL bridges look like the Console design (backlit yellow rectangles); no close-up good enough to copy a specific face was found, so the Console design is the composite of the API bridge and TL Audio/Sifam photos instead of a claimed Studer or Neve copy.
- **Nagra modulometer**: a Nagra-specific instrument (its own ballistics), not one of the IEC types.

Each design carries the word "vespertine" where its maker put its own name, lettered the way that maker lettered it (no crescent; the Original designs keep the app's own mark). No maker's logo or name is reproduced, and no font file is added: the closest typefaces that ship with macOS are used, or the letters are drawn.

| Design | The maker's lettering on the real device | Vespertine's |
|---|---|---|
| Broadcast | Weston 862 card: the maker's line across the top and "MODEL 862" bottom left, in small bold geometric capitals ([600-dpi scan](https://www.preservationsound.com/?p=9246)) | VESPERTINE across the top, TYPE A bottom left, Futura Bold |
| Console | API faces: a small mark top left, printed in thin outline | vespertine top left, Futura Bold as an outline only |
| Tape Recorder | Revox A77 strip: the name in blue, wide heavy flared capitals with the vowels set smaller, a widely spaced line of small black capitals under it | VESPERTINE in Skia Black Extended, vowels smaller, blue; VU - STEREO - METER under it |
| Cassette Deck | Marantz 5030: heavy, very wide lower case with flat serifs, large on the panel and small on each card under "dB"; a Spencerian script for "Stereo Cassette Deck" (custom logo; the faceplates used Metropolis and Davison Spencerian, [Fonts In Use](https://fontsinuse.com/uses/4675/marantz-receivers-1970s)) | vespertine in Superclarendon Black widened 140 %, on the panel and the cards; "Stereo Meters" in Snell Roundhand Bold |
| BBC, BBC Stereo, EBU, Nordic | Sifam 34A: bottom left, an S built of even squared strokes with rounded corners, the type in small squarish figures beside it | VESPERTINE drawn as paths in that construction; the type and PPM in DIN Alternate |
| DIN | Siemens & Halske: tiny black print bottom left and right on the scale; Siemens' corporate lettering is a heavy open sans (Neuzeit S was made for Siemens, [Wikipedia](https://en.wikipedia.org/wiki/Neuzeit_S)) | VESPERTINE in Lucida Grande Bold, thickened and widened, bottom left; DIN 45406 bottom right |

## 4. Telling left and right apart, without breaking the standards

The two channels of most music are close, and two meters with the standard's (deliberately slow, 300 ms) VU ballistics look alike most of the time. Making the needles themselves faster or exaggerated would break the standard. Instead:

- **BBC Stereo** uses what the BBC itself did: twin needles on one dial (red A, green B), so a lead of one channel is a visible gap between two needles on the same scale, and an **S needle** (yellow) that rises with the difference between the channels (zero for mono). Both are Type IIa needles, unchanged; M and S are computed from the same samples (tested: a tone in both channels reads 0 on M and nothing on S; in one channel, -6 dB on both).
- **Balance meter** (Broadcast and Console): a centre-zero meter between the two VUs, reading how many dB louder one side is, ±6 dB across its scale, centring when both are under about -20 VU. It reads the two VU needles and never feeds back into them; its own needle has the VU's damping (tested: 1-1.5 % overshoot), so it moves like a meter, not like a graph. This is Vespertine's addition (a stereo balance indicator in the console style), documented as such, not a claim about any one console.
- **Labels** on every design: engraved LEFT / RIGHT CHANNEL, CHANNEL I / II, big L/R legends, and the UK colour key (red = left, green = right) where the design is British.
- **Per-channel peak lamps** where the real device has them (console, cassette deck).

The standard needles are untouched: a test runs the meters with and without every extra on the same noise and checks the VU and Type IIa readings are bit-identical.

## 5. Not verified

- No physical instrument was measured; faces are reconstructed from photos and the cited text. Colours are matched by eye to photographs taken under unknown light.
- The Weston 862's exact card (minor tick positions, per cent numerals) wasn't found in a close-up; the Broadcast face follows the 1940 paper's description of Type A instead.
- The DIN scale positions are measured from two photos (section 2), not taken from the DIN 45406 text.
- IEC 60268-10's exact tolerances (e.g. on the 10 ms burst for Type I) were not read in the standard itself; Type I is calibrated to the integration-time definition (5 ms burst at 5 kHz reads -2 dB, tested within 0.5 dB) and the return time (20 dB in 1.7 s, tested within 0.5 dB).
- Revox A77 face details (exact numerals) are read from small photos.
- No source names the typefaces of the Revox, Sifam, API or Siemens & Halske marks; the matches in section 3 are made by eye from the photos.
