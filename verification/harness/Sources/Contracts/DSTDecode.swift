//
// Vespertine verification: contracts/dst-decode.md in Swift. Says nothing the document doesn't.
// SPDX-License-Identifier: GPL-3.0-or-later
//

public protocol DSTFrameDecoder: AnyObject {
    /// Decodes one DST frame (1/75 s at 64 × 44 100 Hz). On success, the DSD as channel bytes interleaved in channel
    /// order (byte 0 channel 1, byte 1 channel 2, …), most significant bit oldest. nil when the frame can't be
    /// decoded. The result must not depend on frames decoded earlier.
    func decode(frame: [UInt8]) -> [UInt8]?
}

public protocol DSTDecoderMaker: Sendable {
    /// `channels`: 2, 5 or 6.
    func makeDecoder(channels: Int) -> any DSTFrameDecoder
}

/// One frame of verification/fixtures/dst/ and the DSD it encodes (checked against a reference decoder).
public struct DSTFixture: Sendable, Hashable {
    public var name: String
    public var channels: Int
    /// "dst" (DST-coded) or "uncompressed" (stored as it is).
    public var coding: String
    public var frame: [UInt8]
    public var expected: [UInt8]

    public init(name: String, channels: Int, coding: String, frame: [UInt8], expected: [UInt8]) {
        self.name = name
        self.channels = channels
        self.coding = coding
        self.frame = frame
        self.expected = expected
    }
}
