# Interface contracts

Each contract describes one narrow function or stage that a requirement group is tested through. The clean-room agents (see `../runs/`) receive a contract and the requirement records, and nothing else: no product name, no source code, no existing tests.

Rules every contract follows:

- It states inputs, outputs, encodings, byte and bit order, and error behaviour. It does not say how to compute the result.
- Numbers are exact. Rates are in hertz as 64-bit floats; samples and words are unsigned 32-bit integers unless stated.
- Anything a requirement record leaves open stays open here; the contract never quietly picks a reading.
- A Swift rendering of each contract is in `../harness/Sources/Contracts/`, so the three agents' code compiles against the same types. The Swift file says nothing the document doesn't.

| Contract | Group | Requirements |
|---|---|---|
| [dop-pack.md](dop-pack.md) | DoP packing | `DOP-*` |
| [dop-stream.md](dop-stream.md) | DoP output stream | `DOPS-*` |
| [float-stream.md](float-stream.md) | Float output at unity gain | `FLT-*` |
| [integer-stream.md](integer-stream.md) | Integer-mode output | `INT-*` |
| [bit-perfect-verdict.md](bit-perfect-verdict.md) | BIT-PERFECT verdict | `BPV-*` |
| [rate-plan.md](rate-plan.md) | Device-rate choice and DoP planning | `RATE-*` |
| [dst-decode.md](dst-decode.md) | DST frame decoding | `DST-*` |

The IEC 61937 bitstream group has no contract for blind agents yet: every burst-format requirement is blocked on the paywalled IEC 61937 text (see `../requirements/iec61937.yaml`). Its oracle check is described in `../hardware/IEC61937-ORACLE.md`.
