# Fixtures

`run1927/*.s16z`: recordings from the real-hardware session of 2026-11-07 (quiet room; Fosi ZD3 = clock leader, FiiO K11 = follower
with drift correction, UMIK-1 microphone; `vespertine-probe group-skew ... --keep`). Each file is a 4-byte little-endian float32
scale followed by a raw-deflate stream of int16 little-endian samples (sample = int16 × scale), the whole capture long. Everything
outside the three windows `GroupSkew.measure` reads (the first reference, the follower's slot, the second reference) is zero, which
keeps each file near 64 KB. Run to run, the skews they gave (to 0.001 frame) are reproduced by the full captures; the quantisation
to 16 bits at the capture's own peak changes nothing visible.

- `h3-run-N`: H3 (drift on, lead-in 1.5 s). Runs 2, 6, 13, 16 lost their timing reference in that session; run 18 locked onto a
  later copy (+816 frames instead of about +630); run 1 was a good run (+630.684).
- `h4-run-20`: H4 with a 15 s lead-in; it locked onto a later copy (+801 frames instead of about +639).
