**Vespertine now plays SACD images: add a Super Audio CD rip (`.iso`) and its stereo and 5.1 areas play as DSD, over DoP or converted to PCM, just like DSF and DSDIFF files.**

### SACD images
- **Add an `.iso` like any other file.** Its stereo and multichannel areas become one album, and each song is listed once with both versions: the 5.1 one plays on a multichannel output or with Spatial Audio, the stereo one on a stereo DAC, as with any album that has both.
- **Titles from the disc.** Album, artist, track titles and performers, composers, genre, year, ISRCs and the catalog number come from the disc's own text. Edits stay in the library; the image is never written to.
- **DST decoded to the original DSD.** Most multichannel areas (and some stereo ones) are compressed with DST. Vespertine decodes it back to the exact DSD, so it goes out over DoP bit for bit, with BIT-PERFECT shown as for a DSF file, or through the same DSD → PCM conversion DSDIFF files use.
- **Gapless, as on the disc.** Tracks join without a gap, and seeking lands on the exact spot.
- **Checked on real discs.** Rips of The Dark Side of the Moon and Brothers in Arms play bit for bit as SACD Ripper extracts them, in both areas, DST or not, including track joins and seeks.
- **Damaged images.** An image whose main table of contents is damaged opens from its backup copies, raw rips with 2064-byte sectors open too, and a damaged stretch of audio plays as silence with BIT-PERFECT turned off for that track, rather than as noise. If an image doesn't open or sounds wrong, please [report it](https://github.com/szeremeta1/Vespertine/issues/new?template=bug_report.yml).

### Install
Download **Vespertine-VERSION.dmg**, or let Vespertine update itself. Requires macOS 14.4 or later on Apple silicon or Intel. Signed with a Developer ID (Alexander Szeremeta, `7WMQ9ZV6V8`), notarized and stapled. Homebrew: `brew upgrade --cask vespertine`.
