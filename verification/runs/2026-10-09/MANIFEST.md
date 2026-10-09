# Run manifest

Every deliverable exactly as the agent wrote it (also in `outputs/`), copied unchanged into the harness.

| Group | Role | File | SHA-256 | Lines |
|---|---|---|---|---|
| dop-pack | A | `harness/Sources/SpecChecks/DoPPackChecks.swift` | `04c2f716e34afea40d0c4b118f9bc5fddc5f1e12effb17a8e2dd9630a140f01c` | 741 |
| dop-pack | B | `harness/Sources/CleanRoomB/BDoPPack.swift` | `3fb7817b3b4fe7ed49b25aa9434e8dae1b6080ecd4bf123df7e1e7198ef5685a` | 48 |
| dop-pack | C | `harness/Sources/Mutants/DoPPackMutants.swift` | `1d490273f816293568b8c583fcda5c3c63b82daa493bb90e3b2ea0efebdc094f` | 206 |
| dop-stream | A | `harness/Sources/SpecChecks/DoPStreamChecks.swift` | `b6ce912709bfbfd17fb602eeeccf3ae141276ad252b3a97a3af2a131b9689826` | 1340 |
| dop-stream | B | `harness/Sources/CleanRoomB/BDoPStream.swift` | `3200a0917e47b2da0a33e9bf330cc8cff9c063fdd4c4557334702d59be823712` | 123 |
| dop-stream | C | `harness/Sources/Mutants/DoPStreamMutants.swift` | `4cac633061d4e5caebd5318f828d77dafb1fb4551898ef8b52f9a1ec99b89643` | 684 |
| pcm-stream | A | `harness/Sources/SpecChecks/FloatChecks.swift` | `9ca959c91bf3d26a8a38d5f3ba840245c0a0faba411788fe5b4edbaad399610a` | 1080 |
| pcm-stream | A | `harness/Sources/SpecChecks/IntegerChecks.swift` | `725511dc0b536fbe0be5c0c934024a349a3885b4fa2a20a9c7e5f9675d3548fc` | 911 |
| pcm-stream | B | `harness/Sources/CleanRoomB/BFloat.swift` | `3f49b533a992040fb8aeb2aec9ad47ef46e845d9515b5671c3a1fcd8432d6b2e` | 109 |
| pcm-stream | B | `harness/Sources/CleanRoomB/BInteger.swift` | `0f239ca9a25b506ad38c83f963f6d17a670d8d68ef529c3369637c2431f33531` | 90 |
| pcm-stream | C | `harness/Sources/Mutants/FloatMutants.swift` | `dcd12f1b45fde7752dcc45c0f60cf72451ea9020ee48703bb07813ea68a46cc5` | 437 |
| pcm-stream | C | `harness/Sources/Mutants/IntegerMutants.swift` | `b503c4f1fc8df56fbffc6c21bc97e9db4cc50eb5fc09d80630c8910d1ca33da5` | 340 |
| rate | A | `harness/Sources/SpecChecks/RateChecks.swift` | `7bf78e0913619bc4db5c12491fdd8c814b985da6d71e007d47ce857b9a6af59c` | 813 |
| rate | B | `harness/Sources/CleanRoomB/BRate.swift` | `7743ef551d959d70916ee93f20300f318a8fee24a438fbf85b7ee3479f7f08b0` | 163 |
| rate | B2 | `harness/Sources/CleanRoomB2/B2Rate.swift` | `f04bca10adcdb6280d42374ef719a423cd382d42e831e3cc96edc24ce80c6177` | 120 |
| rate | C | `harness/Sources/Mutants/RateMutants.swift` | `e38d5c63a07fd28086aaf412e6fa249baa16bb6ee1aab33e36810e81cce84b19` | 450 |
| verdict | A | `harness/Sources/SpecChecks/VerdictChecks.swift` | `637a766d6851a0d976f560b887739b479099464129a1fddfe7673b2c7dea23eb` | 884 |
| verdict | B | `harness/Sources/CleanRoomB/BVerdict.swift` | `768030becdb256f612a9e71980b5150e8cb73739a0a71f44ec951e6f9548b3fa` | 156 |
| verdict | B2 | `harness/Sources/CleanRoomB2/B2Verdict.swift` | `07191d32551780e58615f1e3e26bc03e9961318cdd69f309591f90feec6d70b4` | 148 |
| verdict | C | `harness/Sources/Mutants/VerdictMutants.swift` | `a8af8280ba358e4ab6c7db388e7976d1fc4be007a6e702dd53878b7baf8150a7` | 660 |
| dst | A | `harness/Sources/SpecChecks/DSTChecks.swift` | `beb4a3473d81387bb7f5ab596ab8ade48f88c0fc3fc9de040c0cc443516dc41b` | 546 |
| dst | C | `harness/Sources/Mutants/DSTMutants.swift` | `c2f4fa4bbada11937c5d579aa731af0338ac1bea842415f7cb847d33a67878ed` | 329 |
| carrier-scan | | `carrier_scan.py` | `7b49f90458f48666b886867929b6a8a247adcc02b08d4d2076d3515a21f90808` | 1013 |

## Briefs

| Brief | SHA-256 |
|---|---|
| `briefs/carrier-scan.md` | `9b7d71e7a797e58b0db3ed6734948fd4f755b533486964a0b002434d26f1e753` |
| `briefs/dop-pack-A.md` | `d2cd74162e078fe81ec710dd27ae7396dd5d583f780c22fd91d4d83670b508d6` |
| `briefs/dop-pack-B.md` | `3cd66e7eb737e53868bd9bd7de64162c293e1da5742a0b8c6b40019855f91724` |
| `briefs/dop-pack-C.md` | `a5b8d8367193747b832262112374973ef776308a0ded5b00b0b7e1a064f3c927` |
| `briefs/dop-stream-A.md` | `44ead60ea8301e3383095b40155c49ebacc916dde6ef6f598de6bd723ef574f9` |
| `briefs/dop-stream-B.md` | `d4e8a9ab9ca8c7280e624e8dddbc18c6602ea6a53f0310f00422cf4ec1c3ac1d` |
| `briefs/dop-stream-C.md` | `a3580f1078684d71ddfd44c562c1dd99d77f58dd3ea34a48da58f73fe762441e` |
| `briefs/dst-A.md` | `b370ab9481c45922108dcb31a23adb9f76ceb9327a7be1773305c66d1b29c845` |
| `briefs/dst-C.md` | `299ff3d18f617f821a0673fbe62eae2238fbada09e52f4d9e575baafddfca5c9` |
| `briefs/pcm-stream-A.md` | `73fecce7e20719e495f2de12b738533bf2645476e9cee9ab6f6f8391ec60a06f` |
| `briefs/pcm-stream-B.md` | `cc95707a7e32fb6dbdb5b2feb6ce422b230cf4759102c2fc7a0410ce41df3a21` |
| `briefs/pcm-stream-C.md` | `3dd48876d754e61b4c09de0d12594e96057a2548fdc9458af4b1b10430409b79` |
| `briefs/rate-A.md` | `8e62940b541faffc9071413e64da61067ebdd4f1ea8f123829c4a00e3387423e` |
| `briefs/rate-B.md` | `0afda0d707766656fdb21c83d607608d877c4823592cbdc8b9c984fe901d50b6` |
| `briefs/rate-B2.md` | `8fbd4bea8ae2fc0d695b791cd99e45c6e094ecf8b9fd39f644c331c85aadf462` |
| `briefs/rate-C.md` | `01943005e8ea33ff9ebc65178f12f97fdee7deede79df0449067b727aa74c3ee` |
| `briefs/verdict-A.md` | `0cc9f1e3e5ab556cb9977afbba9ca86f0d2f98e24086da749389be74820a09f5` |
| `briefs/verdict-B.md` | `96c30022c0b65716482c91216325a31dab4cf00f3f11648c31442960884356c3` |
| `briefs/verdict-B2.md` | `ea8e3fc698629462c87d8553696332008ff04183c0cdf230fbc50891aa272ccf` |
| `briefs/verdict-C.md` | `cac42025dea10ac5659524f8985e0d2a020667b287d97cceec7000ac8e61dabe` |
