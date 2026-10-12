# Contract: Device-rate choice and DoP planning

Pure functions that decide the rate an audio device is set to and whether DSD is sent as DoP.

## Signatures

```
chooseRate(sourceRate: Double, offeredRates: [Double], policy: Policy) -> Double
dopCarrierRate(dsdRate: Double) -> Double
planDSD(dsdRate: Double, device: DSDDevice) -> DSDPlan
```

## Types

- `Policy`: `matchSource`, `maximum`, or `fixed(rate: Double)`.
- `DSDDevice`:
  - `offeredRates: [Double]`: the nominal rates the device can be set to;
  - `dopEnabled: Bool`: the user marked the device as decoding DoP;
  - `integerBitDepths: [Int]`: bit depths of the integer physical formats the device offers at every one of its rates (for example `[16, 24, 32]`);
  - `channels: Int`: the device's output channel count.
- `DSDPlan`: `mode` (`dop` or `pcm`), `deviceRate: Double` (the rate the device is set to), and `pcmRate: Double?` (for `pcm`: the rate DSD is converted to before any further resampling; nil for `dop`).

## Inputs

- Rates are in hertz. `offeredRates` is non-empty, has no duplicates, and is in no particular order.
- `sourceRate` is a PCM sample rate. `dsdRate` is a DSD bit rate per channel (2 822 400 for DSD64, 5 644 800 for DSD128, …).
- `planDSD` is asked about a stereo DSD source.
- Two rates are equal when they differ by less than 0.5 Hz.

## Output

- `chooseRate` returns one of `offeredRates`, except for `fixed(rate)` when that rate is not offered (not specified).
- `planDSD.deviceRate` is one of `offeredRates`.

## Errors

None.
