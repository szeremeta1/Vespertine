| Kind | Input | Result | Detail |
|---|---|---|---|
| dop | stereo-8B-05 | MATCH | 24 bytes identical |
| dop | stereo-8B-FA | MATCH | 24 bytes identical |
| dop | mono-bitorder | MATCH | 9 bytes identical |
| dop | 6ch-32B | MATCH | 288 bytes identical |
| dop | stereo-8192B | MATCH | 24576 bytes identical |
| dop | silence-like-0x69 | MATCH | 48 bytes identical |
| ac3 | 48k-128kbps-bsmod0 | MATCH | 6144 bytes identical |
| ac3 | 48k-640kbps-bsmod7 | MATCH | 6144 bytes identical |
| ac3 | 44k1-odd-words-bsmod2 | MATCH | 6144 bytes identical |
| ac3 | 32k-max-3840B-bsmod1 | MATCH | 6144 bytes identical |
| ac3 | 48k-32kbps-bsmod4 | MATCH | 6144 bytes identical |
| eac3 | 1x6blk-768B | MATCH | 24576 bytes identical |
| eac3 | 2x3blk | MATCH | 24576 bytes identical |
| eac3 | 6x1blk | MATCH | 24576 bytes identical |
| eac3 | ind+dep-6blk | MATCH | 24576 bytes identical |
| eac3 | max-6blk-4096B | MATCH | 24576 bytes identical |
| eac3 | over-capacity-6x4096B | REF-REFUSES | reference refuses (BurstError: burst does not fit in its repetition period); Vespertine produced 24576 bytes |
| dts | 512-1006B | MATCH | 2048 bytes identical |
| dts | 512-odd-1007B | REF-REFUSES | reference refuses (BurstError: odd DTS frame size cannot be packed in 16-bit words); Vespertine produced 2048 bytes |
| dts | 1024-2012B | MATCH | 4096 bytes identical |
| dts | 2048-4000B | MATCH | 8192 bytes identical |
| dts | 512-fills-2040B | MATCH | 2048 bytes identical |
| dts | 512-over-2044B | REF-REFUSES | reference refuses (BurstError: frame does not fit in the repetition period together with the preamble); Vespertine produced 2048 bytes |
| eac3_group | 12x1blk | MATCH | same groups |
| eac3_group | ind-dep-x3 | MATCH | same groups |
| eac3_group | 4x3blk | MATCH | same groups |
| eac3_group | 2x6blk-sub0+sub1 | MATCH | same groups |
| ac3_stream | 48k-192kbps-x5 | MATCH | 30720 bytes identical |
| eac3_stream | 3blk-x8 | MATCH | 98304 bytes identical |
| eac3_stream | ind+dep-x4 | MATCH | 98304 bytes identical |
