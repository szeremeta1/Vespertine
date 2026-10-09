//
// Vespertine verification: contracts/dst-decode.md connected to Vespertine's DST decoder (vespertine_dst.c), as
// SACDDecoder uses it: one decoder per area, 4704 bytes per channel per frame (DSD64). On Linux the same file is
// compiled from Packages/ through the DSTUnderTest target (a symlink, not a copy).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Contracts
#if canImport(DSTUnderTest)
import DSTUnderTest
#else
import CVespertineDTS
#endif

final class NDSTFrameDecoder: DSTFrameDecoder {
    let decoder: OpaquePointer?
    let channels: Int
    static let frameBytes = 4704

    init(channels: Int) {
        self.channels = channels
        decoder = ndst_create(Int32(clamping: channels), Int32(Self.frameBytes))
    }

    deinit { ndst_destroy(decoder) }

    func decode(frame: [UInt8]) -> [UInt8]? {
        guard let decoder, !frame.isEmpty else { return nil }
        var out = [UInt8](repeating: 0, count: channels * Self.frameBytes)
        let ok = frame.withUnsafeBufferPointer { input in
            out.withUnsafeMutableBufferPointer { output in
                ndst_decode(decoder, input.baseAddress!, Int32(clamping: input.count), output.baseAddress!)
            }
        }
        return ok ? out : nil
    }
}

struct NDSTDecoderMaker: DSTDecoderMaker {
    func makeDecoder(channels: Int) -> any DSTFrameDecoder { NDSTFrameDecoder(channels: channels) }
}
