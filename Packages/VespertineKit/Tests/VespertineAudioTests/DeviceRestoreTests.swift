//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

/// One output stream whose format changes take a few reads to show, as Core Audio's do (they are asynchronous).
private final class SlowStream: @unchecked Sendable {
    var formats: [AudioObjectPropertySelector: AudioStreamBasicDescription]
    private var pending: [AudioObjectPropertySelector: (format: AudioStreamBasicDescription, readsLeft: Int)] = [:]
    let delay: Int
    var log: [String] = []
    var pauses = 0

    init(physical: AudioStreamBasicDescription, virtual: AudioStreamBasicDescription, delay: Int) {
        formats = [kAudioStreamPropertyPhysicalFormat: physical, kAudioStreamPropertyVirtualFormat: virtual]
        self.delay = delay
    }

    static func name(_ s: AudioObjectPropertySelector) -> String { s == kAudioStreamPropertyPhysicalFormat ? "physical" : "virtual" }

    var io: DeviceRestore.StreamFormatIO {
        DeviceRestore.StreamFormatIO(
            read: { [self] selector in
                if var p = pending[selector] {
                    p.readsLeft -= 1
                    if p.readsLeft <= 0 { formats[selector] = p.format; pending[selector] = nil } else { pending[selector] = p }
                }
                return formats[selector]
            },
            write: { [self] selector, format in
                // A change made while another is still under way is how a device can end up paused for good: noted.
                if let other = pending.first(where: { $0.key != selector }) {
                    log.append("set \(Self.name(selector)) while \(Self.name(other.key)) was changing")
                }
                log.append("set \(Self.name(selector))")
                pending[selector] = (format, delay)
            },
            pause: { [self] in pauses += 1 }, settle: { [self] in log.append("settle") })
    }
}

private func lpcm(_ rate: Double, bits: UInt32, float: Bool, nonMixable: Bool = false) -> AudioStreamBasicDescription {
    var flags = float ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger
    flags |= kAudioFormatFlagIsPacked
    if nonMixable { flags |= kAudioFormatFlagIsNonMixable }
    return AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
                                       mBytesPerPacket: bits / 8 * 2, mFramesPerPacket: 1, mBytesPerFrame: bits / 8 * 2,
                                       mChannelsPerFrame: 2, mBitsPerChannel: bits, mReserved: 0)
}

@Suite("Putting a device back on quit")
struct DeviceRestoreTests {
    @Test("The physical format is read back and settles before the virtual format is put back, and both end as they were")
    func physicalThenVirtual() {
        // Left in integer mode at 176.4 kHz; it was 24-bit at 44.1 kHz with a Float32 virtual format.
        let stream = SlowStream(physical: lpcm(176_400, bits: 32, float: false, nonMixable: true),
                                virtual: lpcm(176_400, bits: 32, float: false, nonMixable: true), delay: 3)
        let physical = lpcm(44_100, bits: 24, float: false), virtual = lpcm(44_100, bits: 32, float: true)
        DeviceRestore.putBack(physical: physical, virtual: virtual, io: stream.io)
        #expect(stream.log == ["set physical", "settle", "set virtual", "settle"])
        _ = stream.io.read(kAudioStreamPropertyVirtualFormat)
        #expect(stream.formats[kAudioStreamPropertyPhysicalFormat].map { DeviceControl.isSameFormat($0, physical) } == true)
        #expect(stream.formats[kAudioStreamPropertyVirtualFormat].map { DeviceControl.isSameFormat($0, virtual) } == true)
    }

    @Test("A format already as it was isn't set again")
    func nothingToDo() {
        let physical = lpcm(48_000, bits: 24, float: false), virtual = lpcm(48_000, bits: 32, float: true)
        let stream = SlowStream(physical: physical, virtual: virtual, delay: 3)
        DeviceRestore.putBack(physical: physical, virtual: virtual, io: stream.io)
        #expect(stream.log.isEmpty)
    }

    @Test("A device that never reports the change is waited for a bounded number of reads, then the next step goes ahead")
    func boundedWait() {
        let stream = SlowStream(physical: lpcm(96_000, bits: 32, float: false), virtual: lpcm(96_000, bits: 32, float: true), delay: 10_000)
        DeviceRestore.putBack(physical: lpcm(44_100, bits: 24, float: false), virtual: lpcm(44_100, bits: 32, float: true), io: stream.io)
        #expect(stream.log.first == "set physical" && stream.log.contains("set virtual while physical was changing"))
        // Both changes waited for in full: 2 × 50 pauses of 10 ms, a second at most, which leaves the rate step room in the
        // 2.5 s quit budget.
        #expect(stream.pauses == 2 * DeviceRestore.restorePolls)
        #expect(Double(stream.pauses) * 0.010 + 2 * 0.060 <= QuitSequence.defaultBudget / 2)
    }
}
