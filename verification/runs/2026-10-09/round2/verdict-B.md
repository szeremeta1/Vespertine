# Review round 2: verdict-B

Sent to the same agent, resumed in its own workspace, after the F-05 docs change and the new BPV-018 record (FINDINGS.md F-05, H-01). It carries the changed records and contract text only: nothing about how any implementation scored.

The product's documentation changed: the rules for DoP, bitstream and integer mode now say when the player
must hold the device. Two requirement records changed, one is new, and one contract row changed. This is a second
review round; the rules of your brief still apply in full (work only in /srv/cleanroom/verdict-B, Bash only as
`swiftbox /srv/cleanroom/verdict-B "<command>"`, no other paths or tools).

These records replace BPV-016 and BPV-017 in your brief, and BPV-018 is new. Every other record is unchanged.

```yaml
- id: BPV-016
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: For DoP the badge is "NATIVE DSD · DoP" exactly when the player holds the device (BPV-009), the nominal
    rate read back equals the planned carrier rate, the physical format has ≥24 bits, and BPV-006 to BPV-011 and
    BPV-013 hold.
  testable: true
  gap: Shared mode with no other app playing is not enough for DoP. The docs don't say whether the 24-bit physical
    format must be integer. A DoP track whose player doesn't hold the device doesn't play; what the badge then says
    isn't specified beyond not being "NATIVE DSD · DoP".
- id: BPV-017
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: For bitstream the badge starts "BITSTREAM · " only when the player holds the device (BPV-009), the
    nominal rate read back equals the planned rate, the physical format is integer with at least 16 bits, and the
    shared conditions hold.
  testable: true
  gap: Bitstream always takes the device exclusively and doesn't play without it, as DoP does (BPV-016), so shared
    mode with no other app playing is not enough. The codec name after the dot isn't specified.
- id: BPV-018
  kind: product-rule
  source:
    doc: the product's own documentation (a rule the product sets for itself)
    availability: product rule
  requirement: Integer mode is in effect only while the player holds the device exclusively (BPV-009); a path with
    integer mode in effect and the device not held doesn't occur. Without exclusive access the player uses the 32-bit
    float path.
  testable: false
  gap: 'This is a condition on the verdict''s inputs, enforced where the player configures the device, so the verdict
    alone can''t show it. Checking it needs a real device: with shared mode chosen, a 32-bit source plays through
    the float path. A source deeper than 24 bits is bit-perfect only in integer mode (BPV-005), so it is never bit-perfect
    unless the player holds the device.'
```

The contract's `integerMode` row now reads (its doc comment in `harness/Sources/Contracts/Verdict.swift` is already
updated in your workspace; nothing else in that file changed):

| `integerMode` | Bool | the player is sending 32-bit integers straight to the device, with no 32-bit float step. Only ever true while the player holds the device exclusively (`readback.hogOwnerPID == readback.ownPID`; BPV-018): inputs with `integerMode` true and the device not held don't occur |

Bring your implementation in line with the records and the contract as they now stand, so that every record with
`testable: true` holds. Rebuild with `swiftbox /srv/cleanroom/verdict-B "cd harness && swift build"`. Finish with a short report: what
you changed and why (by requirement ID), and any new ambiguity.
