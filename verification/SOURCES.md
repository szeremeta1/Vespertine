# Sources

Every document the requirement records cite, with the exact edition, where it was opened and the SHA-256 of the file read. All were opened on 2026-10-09. The container that built this harness can't reach dsd-guide.com, atsc.org, etsi.org, iec.ch or iso.org, so those were opened on Alex's Mac and copied into the git-ignored spec cache; `raw.githubusercontent.com` was opened from both. "HTTP 200" means the URL returned the file directly, with no redirect.

`tools/spec_cache.py fetch` downloads the public documents again and refuses any file whose SHA-256 differs from the one below, so a record's hash can always be checked against the edition it was written from.

## Public specifications

| Cache ID | Document | Edition | SHA-256 of the PDF | Pages | Opened at | Cited by |
|---|---|---|---|---|---|---|
| `dop-1.1` | DoP Open Standard: Method for transferring DSD Audio over PCM Frames | 1.1, 2012-03-30 | `640ff447f1456186927365cf422622e3665634b99dbd7c56b39f77e6720f1a4c` | 4 | https://dsd-guide.com/sites/default/files/white-papers/DoP_openStandard_1v1.pdf (HTTP 200) | DOP-001…005, DOPS-001, DOPS-002, RATE-001, RATE-002 |
| `dsdiff-1.5` | Philips DSDIFF: Direct Stream Digital Interchange File Format | 1.5, 2004-04-27 | `fba0c3053c81f7af93eb8bb3ea70b6f78bb1188578a844c054988af2ff2f0b01` | 34 | https://dsd-guide.com/sites/default/files/white-papers/DSDIFF_1.5_Spec.pdf (HTTP 200) | DOP-006, DOPS-003, DST-001, DST-002 |
| `dsf-1.01` | Sony DSF File Format Specification | 1.01 | `2c154f3e82ea835a8023d08308adc26344b0fcec627c14e585640e0111740da4` | 6 | https://dsd-guide.com/sites/default/files/white-papers/DSFFileFormatSpec_E.pdf (HTTP 200) | CLAIMS.md (`dop-file-bit-order`); no record yet |
| `atsc-a52-2018` | ATSC A/52:2018, Digital Audio Compression (AC-3, E-AC-3) Standard | 2018 (newest on atsc.org) | `4580b631f5ac1aafdd31034f28d5fc9c29bce72a3d3f6367e3d9746906e0ffa1` | 271 | https://www.atsc.org/wp-content/uploads/2021/04/A52-2018.pdf (HTTP 200) | IEC-O-002 (the frame syntax the carrier scanner reads) |
| `etsi-ts-102114-1.6.1` | ETSI TS 102 114, DTS Coherent Acoustics; Core and Extensions | V1.6.1 (newest in etsi.org/deliver) | `29f9e50575e48bfe55222c5f004088af379bc9a6c65274ed975a81dca10647ba` | 298 | https://www.etsi.org/deliver/etsi_ts/102100_102199/102114/01.06.01_60/ts_102114v010601p.pdf (HTTP 200) | IEC-O-002 |
| `etsi-ts-102366-1.4.1` | ETSI TS 102 366, Digital Audio Compression (AC-3, Enhanced AC-3) Standard | V1.4.1 (newest in etsi.org/deliver) | `0229e151dfd9f8cec427f234798cac679a66fdec096feecc4d5ce455bbe3cadf` | 244 | https://www.etsi.org/deliver/etsi_ts/102300_102399/102366/01.04.01_60/ts_102366v010401p.pdf (HTTP 200) | Cross-check of A/52 only; no record |

Two text extractors were used on each PDF: poppler's `pdftotext` (in the container) and PDFKit (on the Mac). Every clause hash in the records came out the same from both, which is why the hash is over the canonical form described in `requirements/README.md`.

## Apple Core Audio

| Source | Edition | SHA-256 | Opened at | Cited by |
|---|---|---|---|---|
| `AudioHardware.h` (CoreAudio.framework) | macOS 27.0 SDK, build 26A425 (Xcode 27.0, 27A266a) | `a699437248e079d9ebe47078ef3861492d8253fef1a6007e476031031d3535ca` | Copied from the SDK on Alex's Mac, `cmp`-identical | BPV-009 (the comment on `kAudioDevicePropertyHogMode`) |
| `AudioHardwareBase.h` (CoreAudio.framework) | same SDK | `cbac54e8edb7ee99bf10c18a2db044e01c47645985b2f2824623f3f8371a7c4e` | same | Background only |
| `CoreAudioBaseTypes.h` (CoreAudioTypes.framework) | same SDK | `f58c4e2bccc86193afa89160bba76ab57989138e8885bed1c068d41ebe2b5c86` | same | Background only |
| kAudioDevicePropertyHogMode documentation page | DocC JSON as served 2026-10-09 | `06bdb21abfef282514db3dbb4ea159fd37cd2a5b1079786113d41b60cc2b0c88` (JSON) | https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertyhogmode (HTTP 200) | BPV-009's URL |

The header is the interface definition, not sample code. No record cites Apple sample code.

## Vespertine's own documentation

`vespertine-rule` records cite `docs/VERIFICATION.md`, `docs/FEATURES.md` and `docs/ARCHITECTURE.md` in this repository at the commit named in each record. `tools/check_registry.py` recomputes their hashes from the working tree on every CI run, so a doc edit that changes a cited sentence fails CI until the record is reviewed.

## Oracles (implementations; never the source of a `spec` record)

| Oracle | Version | Files and SHA-256 | Fetched from | Record |
|---|---|---|---|---|
| libdstdec, the MPEG-4 Audio reference module for DST (Philips), as distributed with SACD Ripper | sacd-ripper commit `a3d981c935c3224217e2842cd492f9351106c81e` (2023-01-14) | 14 files in `libs/libdstdec/`; tree digest `593a13163daf6a8f8573c7f059ad562accd39acc8ad6ea3aa41cb42f021f18b4` | https://raw.githubusercontent.com/sacd-ripper/sacd-ripper/a3d981c935c3224217e2842cd492f9351106c81e/libs/libdstdec/ | DST-003 |
| FFmpeg S/PDIF demuxer | n6.1.1, the version Ubuntu 24.04 packages (`ffmpeg 7:6.1.1-3ubuntu5`) | `spdifdec.c` `3d795daf73b8e8af1b4091f4ff054ea211e7f330de36a209ab49f31c363ed41d`, `spdif.h` `e66963e5277d5bd76494b021af6adc48c91aeb132fcc8749692b226be19df535`, `spdif.c` `cef204bc3ae547a98e69c78457d448baeb3bee2166da65286f8794daccaf364e`; tree digest `7bd77701b22c5492b6c2fd6d53f2add19a1b7a6e42c91ce98b7362943f982ec9` | https://raw.githubusercontent.com/FFmpeg/FFmpeg/n6.1.1/libavformat/ | IEC-O-001 |
| Independent carrier scanner | this harness, `oracles/carrier-scan/carrier_scan.py` | hashed in its record | written blind from A/52 and TS 102 114 (see `hardware/IEC61937-ORACLE.md`) | IEC-O-002 |
| sacd_extract | "Enhanced sacd_extract" 0.3.9.3 pre-release, Linux x86-64 build of 2021-12-13 | binary `2f3a280c73d0e8f49c5ad2071d4949e1f621a7987d758dc1123e886746c70bab` | Already on Alex's Mac and home server | `hardware/SACD-ORACLE.md` |

`tools/fetch_oracles.py` fetches the first two at those exact versions into the git-ignored `oracles/fetched/` and stops if the digest differs. They are fetched rather than vendored: libdstdec's ISO licence covers products claiming MPEG-4 Audio conformance, and keeping an upstream copy separate makes clear the oracle isn't part of Vespertine.

## Paywalled: not bought

Alex decided on 2026-10-09 not to buy these for now and to use oracle evidence instead. Every requirement that depends on them is in the registry as `quote_sha256: BLOCKED`, `status: blocked-on-source`, with the clause numbers taken from the table of contents in each document's free preview (the clause text itself wasn't seen). Prices are the publishers' list prices on 2026-10-09.

| Buy | Price | Unlocks | Store page |
|---|---|---|---|
| IEC 61937-1:2021, edition 3.0 (General) | CHF 160 | IEC-001 burst-preamble, IEC-002 burst-payload length, IEC-003 stuffing and byte order | https://webstore.iec.ch/en/publication/62828 |
| IEC 61937-2:2021 (CHF 80) + AMD1:2026 (CHF 10), or the 3.1 consolidated version (CHF 155) | CHF 90 | IEC-004 data-type codes. Amendment 1 (February 2026) is recent; whether it changes these codes is unknown | https://webstore.iec.ch/en/publication/66291, /87533 (CSV: /112261) |
| IEC 61937-3:2017 (CHF 80) + AMD1:2020 (CHF 10), or the 3.1 consolidated version (CHF 155) | CHF 90 | IEC-005 AC-3 burst, IEC-006 E-AC-3 burst | https://webstore.iec.ch/en/publication/32333, /66295 (CSV: /67665) |
| IEC 61937-5:2006 (CHF 80) + AMD1:2019 (CHF 20), or the 2.1 consolidated version (CHF 170) | CHF 100 | IEC-007 DTS type I–III bursts | https://webstore.iec.ch/en/publication/6134, /60178 (CSV: /64573) |
| ISO/IEC 14496-3:2019, edition 5 (1443 pages; only subpart 10 is needed but it is sold whole) | CHF 227 | DST-005, the DST decoding process. DST would then rest on the standard rather than on agreement with the reference decoder | https://www.iso.org/standard/76383.html |

The four IEC 61937 parts come to **CHF 440** bought as base plus amendment (CHF 640 as consolidated versions). With ISO/IEC 14496-3 the total is **CHF 667**.

Priced but not needed by any current record:

| Document | Price | Why it isn't on the list |
|---|---|---|
| IEC 60958-3:2021, edition 4.0 (consumer channel status) | CHF 380 | Defines the channel-status bits, including the one that marks a stream as not linear PCM. Vespertine's code never sets channel status (no reference in `Packages/VespertineKit/Sources`), so there is no Vespertine behaviour here to test. |
| AES3-2009 (R2019) | EUR 78.99 excl. VAT at NSAI (https://shop.standards.ie/en-ie/standards/aes-3-2009-r2019--34050_saig_aes_aes_2755081/) | The professional counterpart of IEC 60958; nothing cited. The AES store itself (https://www.aes.org/publications/standards/) answers with a Cloudflare human check, so its price is unconfirmed, and the listing doesn't say whether it is one part or all four. |

## Previews (front matter only)

Used only for the clause numbers in the BLOCKED records. No clause text from them is cited or hashed.

| File | Product | SHA-256 |
|---|---|---|
| `info_iec61937-1_ed3.0_b.pdf` | IEC 61937-1:2021 | `b09173296ee93891c3a76a95aaff5b19ec7ff0ed2ac947c8a5ed744052938501` |
| `info_iec61937-2_ed3.1_en.pdf` | IEC 61937-2:2021+AMD1:2026 CSV | `32ab609bf25d4322dac2a4084072e7dfb8b1a7881cc600845fe1f4f05985d845` |
| `info_iec61937-3_ed3.1_en.pdf` | IEC 61937-3:2017+AMD1:2020 CSV | `cb7b28d59a036ef1bba7e40451dbb48a7b2d09158d0843591e50e95da1216da9` |
| `info_iec61937-5_ed2.1_en.pdf` | IEC 61937-5:2006+AMD1:2019 CSV | `7528adf7a862ba189e8fc467563d8be19bd0f8f41b41e91fd51e74c5ab3c51d5` |

Each was opened through the webstore's Preview button (`https://webstore.iec.ch/en/iec_catalog/product/preview/?id=…`, HTTP 200).

## Not available at any price

| Document | Status | Consequence |
|---|---|---|
| Super Audio CD System Description ("Scarlet Book") 1.3 | Licensed to SACD licensees only | DST-006 is BLOCKED with no purchase route. Reading SACD images stays oracle evidence against sacd_extract (`hardware/SACD-ORACLE.md`). |

## Could not be opened

| What | Where | Effect |
|---|---|---|
| FFmpeg's FATE sample suite (real DST and IEC 61937 samples) | https://fate-suite.ffmpeg.org/ | Blocked from both the container and the Mac's sandbox. DST fixtures are generated instead (`fixtures/dst/README.md`) and checked against libdstdec. |
| AES standards store | https://www.aes.org/publications/standards/ | Cloudflare human check; see the AES3 row above. |
