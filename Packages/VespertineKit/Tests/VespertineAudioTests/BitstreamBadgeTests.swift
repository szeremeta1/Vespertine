//
// Vespertine: a 5.1 Dolby or DTS stream sent to a receiver as a bitstream goes out as two-channel IEC 61937 frames that carry all
// six channels. Nothing is mixed down, and the signal path must not say it was.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
@testable import VespertineAudio

@Suite("Bitstream badge")
struct BitstreamBadgeTests {
    @Test("A 5.1 Dolby or DTS bitstream is never called a downmix", arguments: ["Dolby Digital", "DTS"])
    func noDownmixForBitstream(codec: String) throws {
        let source = SourceFormat(encoding: .lossy, codec: codec, sampleRate: 48_000, bitDepth: nil, channels: 6)
        let hdmi = DeviceCapabilities(sampleRates: [44_100, 48_000, 96_000, 192_000],
                                      physicalFormats: [PhysicalFormat(minRate: 32_000, maxRate: 192_000, bitDepth: 24, isInteger: true, isMixable: true, channels: 8)],
                                      outputChannels: 8, supportsDoP: false)
        let plan = FormatPlanner.plan(source: source, device: hdmi, bitstream: true)
        try #require(plan.mode == .bitstream && plan.channels == 2)
        let path = SignalPath(source: source, decoderName: "test", plan: plan,
                              applied: AppliedFormat(sampleRate: plan.deviceSampleRate, physicalBitDepth: 24, physicalIsInteger: true,
                                                     virtualChannels: 8, exclusive: true, bufferFrames: 512),
                              deviceName: "Receiver", deviceUID: "test",
                              deviceProfile: DeviceProfile(kind: .usbDAC, tag: "", canBeBitPerfect: true, symbol: "x"), volume: .fixed)
        #expect(path.statusLine != "Downmixed to stereo", "\(codec): \(path.statusLine)")
        #expect(path.conversion?.downmix == nil)
    }
}
