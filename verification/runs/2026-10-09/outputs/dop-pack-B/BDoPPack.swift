import Contracts

/// Role B implementation of the DoP packing contract.
public enum BDoPPack {
    public static let subject: (any DoPPacker)? = Packer()

    struct Packer: DoPPacker {
        private static let markerA: UInt8 = 0x05
        private static let markerB: UInt8 = 0xFA

        func dopPack(dsd: [[UInt8]], firstMarker: UInt8) throws -> [[UInt32]] {
            // Validation (contract "Errors").
            guard let first = dsd.first else { throw InvalidInput() }
            let length = first.count
            guard length % 2 == 0 else { throw InvalidInput() }
            for channel in dsd where channel.count != length {
                throw InvalidInput()
            }
            guard firstMarker == Self.markerA || firstMarker == Self.markerB else {
                throw InvalidInput()
            }

            let periods = length / 2
            let secondMarker = firstMarker == Self.markerA ? Self.markerB : Self.markerA
            let markerEven = UInt32(firstMarker) << 16
            let markerOdd = UInt32(secondMarker) << 16

            var output: [[UInt32]] = []
            output.reserveCapacity(dsd.count)
            for channel in dsd {
                var samples: [UInt32] = []
                samples.reserveCapacity(periods)
                var j = 0
                while j < periods {
                    // Input bytes have their oldest DSD bit in the MSB; slot t0 (oldest) is bit 15 of the
                    // 16 data bits, so the older byte fills bits 15...8 and the newer byte bits 7...0, as is.
                    let older = UInt32(channel[2 * j])
                    let newer = UInt32(channel[2 * j + 1])
                    let marker = (j & 1) == 0 ? markerEven : markerOdd
                    samples.append(marker | (older << 8) | newer)
                    j += 1
                }
                output.append(samples)
            }
            return output
        }
    }
}
