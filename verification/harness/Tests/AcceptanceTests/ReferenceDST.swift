//
// Vespertine verification: the DST group's reference side.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// No one can write a DST decoder blind: the decoding process is in ISO/IEC 14496-3, which isn't in hand (DST-005).
// So instead of a clean-room implementation, the DST group's reference is the MPEG-4 reference decoder's answer for
// each fixture frame: oracles/dst/check_fixtures.py confirms in CI that libdstdec decodes every fixture frame to
// its .dsd, and this decoder returns that .dsd for the fixture frame it is given (nil for any other bytes).

import Contracts
import SpecKit

struct ReferenceAnswers: DSTDecoderMaker {
    func makeDecoder(channels: Int) -> any DSTFrameDecoder { Decoder(channels: channels) }

    final class Decoder: DSTFrameDecoder {
        let channels: Int
        init(channels: Int) { self.channels = channels }
        func decode(frame: [UInt8]) -> [UInt8]? {
            DSTFixtures.all.first { $0.channels == channels && $0.frame == frame }?.expected
        }
    }
}
