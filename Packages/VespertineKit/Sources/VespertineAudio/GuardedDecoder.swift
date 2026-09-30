//
// Vespertine — wraps a decoder so a codec library's exception on a damaged file is an error, not a crash.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import CVespertineGuard
import Foundation
import SFBAudioEngine

final class GuardedDecoder: NSObject, PCMDecoding {
    let inner: PCMDecoding
    /// libtta (SFBAudioEngine 0.14.0) writes one byte past the frames it returns for 24-bit audio, which
    /// overruns a buffer it fills to the last frame and corrupts the heap: that frame is left free.
    private let reservesLastFrame: Bool
    init(_ inner: PCMDecoding) {
        self.inner = inner
        reservesLastFrame = String(describing: type(of: inner)).contains("TrueAudio")
    }

    var inputSource: InputSource { inner.inputSource }
    var sourceFormat: AVAudioFormat { inner.sourceFormat }
    var processingFormat: AVAudioFormat { inner.processingFormat }
    var decodingIsLossless: Bool { inner.decodingIsLossless }
    var properties: [AudioDecodingPropertiesKey: Any] { inner.properties }
    var isOpen: Bool { inner.isOpen }
    var supportsSeeking: Bool { inner.supportsSeeking }
    var position: AVAudioFramePosition { inner.position }
    var length: AVAudioFramePosition { inner.length }

    func open() throws { try Self.check { nguard_open(inner, $0) } }
    func close() throws { try inner.close() }
    func decode(into buffer: AVAudioBuffer) throws {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        try decode(into: pcm, length: pcm.frameCapacity)
    }
    func decode(into buffer: AVAudioPCMBuffer, length: AVAudioFrameCount) throws {
        let length = reservesLastFrame && buffer.frameCapacity > 1 ? min(length, buffer.frameCapacity - 1) : length
        try Self.check { nguard_decode(inner, buffer, length, $0) }
    }
    func seek(to frame: AVAudioFramePosition) throws { try Self.check { nguard_seek(inner, frame, $0) } }

    private static func check(_ call: (NSErrorPointer) -> Bool) throws {
        var error: NSError?
        guard call(&error) else { throw error ?? NSError(domain: "org.szeremeta.vespertine.decoder", code: -1) }
    }
}
