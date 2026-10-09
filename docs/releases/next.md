**Vespertine now plays SACD images: add a Super Audio CD rip (`.iso`) and its stereo and 5.1 areas play as DSD, over DoP or converted to PCM, just like DSF and DSDIFF files.**

### SACD images
- **Add an `.iso` like any other file.** Its stereo and multichannel areas become one album, and each song is listed once with both versions: the 5.1 one plays on a multichannel output or with Spatial Audio, the stereo one on a stereo DAC, as with any album that has both.
- **Titles from the disc.** Album, artist, track titles and performers, composers, genre, year, ISRCs and the catalog number come from the disc's own text. Edits stay in the library; the image is never written to.
- **DST decoded to the original DSD.** Most multichannel areas (and some stereo ones) are compressed with DST. Vespertine decodes it back to the exact DSD, so it goes out over DoP bit for bit, with BIT-PERFECT shown as for a DSF file, or through the same DSD → PCM conversion DSDIFF files use.
- **Gapless, as on the disc.** Tracks join without a gap, and seeking lands on the exact spot.
- **Tested on synthesized images.** The reader was checked against SACD images generated to the Scarlet Book layout, and the DST decoder against FFmpeg's on a real DST sample, but not yet against a rip of a real disc. If an image doesn't open or sounds wrong, please [report it](https://github.com/szeremeta1/Vespertine/issues/new?template=bug_report.yml).

### Install
Download **Vespertine-VERSION.dmg**, or let Vespertine update itself. Requires macOS 14.4 or later on Apple silicon or Intel. Signed with a Developer ID (Alexander Szeremeta, `7WMQ9ZV6V8`), notarized and stapled. Homebrew: `brew upgrade --cask vespertine`.
