//
// Vespertine — speaker groups: each member DAC is put in its best physical format when the group opens, as a single device is.
// Found on real DACs (2026-11-07): the FiiO K11 comes up in 16-bit integer after it is plugged in, and the group kept it there
// (the aggregate is multi-stream, so the single-device format step never touched the members), so the resampled follower was
// cut to 16 bits, and a 16-bit leader could never be BIT-PERFECT for a 24-bit song although the DAC takes 24 and 32 bits.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Testing
@testable import VespertineAudio

@Suite("Group member physical format")
struct GroupMemberFormatTests {
    static func pcm(_ bits: UInt32, integer: Bool = true, channels: UInt32 = 2, rate: Double, mixable: Bool = true) -> AudioStreamRangedDescription {
        var flags: AudioFormatFlags = integer ? kAudioFormatFlagIsSignedInteger : kAudioFormatFlagIsFloat
        flags |= kAudioFormatFlagIsPacked
        if !mixable { flags |= kAudioFormatFlagIsNonMixable }
        let bytes = (integer ? (bits == 24 ? 3 : bits / 8) : 4) * channels
        let f = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags, mBytesPerPacket: bytes,
                                            mFramesPerPacket: 1, mBytesPerFrame: bytes, mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0)
        return AudioStreamRangedDescription(mFormat: f, mSampleRateRange: AudioValueRange(mMinimum: rate, mMaximum: rate))
    }

    /// What the FiiO K11 offers (read on the laptop): int16, int24 and int32 at each rate, each mixable and not.
    static func fiio(_ rates: [Double] = [44_100, 48_000, 96_000, 192_000]) -> [AudioStreamRangedDescription] {
        rates.flatMap { r in [16, 24, 32].flatMap { b in [pcm(UInt32(b), rate: r), pcm(UInt32(b), rate: r, mixable: false)] } }
    }

    @Test("A group member offering 16, 24 and 32-bit integer gets 32-bit integer, mixable, at the group's rate")
    func deepestIntegerForAMember() throws {
        let current = Self.pcm(16, rate: 48_000).mFormat
        let best = try #require(DeviceControl.bestPhysicalFormat(Self.fiio(), rate: 96_000, channels: 2, bitDepth: GroupMemberSession.memberBitDepth, current: current))
        #expect(best.mBitsPerChannel == 32)
        #expect(best.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0)
        #expect(best.mFormatFlags & kAudioFormatFlagIsNonMixable == 0)
        #expect(best.mSampleRate == 96_000)
        #expect(best.mChannelsPerFrame == 2)
    }

    @Test("The single-device choice is unchanged: a 24-bit song on a DAC that takes 24 gets 24")
    func singleDeviceChoiceUnchanged() throws {
        let best = try #require(DeviceControl.bestPhysicalFormat(Self.fiio(), rate: 48_000, channels: 2, bitDepth: 24, current: nil))
        #expect(best.mBitsPerChannel == 24 && best.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0)
    }

    @Test("Formats at other rates, with too few channels, or not PCM are never chosen; a float-only device keeps float")
    func onlyUsableFormats() throws {
        #expect(DeviceControl.bestPhysicalFormat(Self.fiio([44_100]), rate: 48_000, channels: 2, bitDepth: 32, current: nil) == nil)
        #expect(DeviceControl.bestPhysicalFormat([Self.pcm(32, channels: 1, rate: 48_000)], rate: 48_000, channels: 2, bitDepth: 32, current: nil) == nil)
        let float = try #require(DeviceControl.bestPhysicalFormat([Self.pcm(32, integer: false, rate: 48_000)], rate: 48_000, channels: 2, bitDepth: 32, current: nil))
        #expect(float.mFormatFlags & kAudioFormatFlagIsFloat != 0)
    }

    @Test("A member already in its best format is left alone (no format change, so no re-lock)")
    func alreadyBestIsSame() throws {
        let current = Self.pcm(32, rate: 48_000).mFormat
        let best = try #require(DeviceControl.bestPhysicalFormat(Self.fiio(), rate: 48_000, channels: 2, bitDepth: 32, current: current))
        #expect(DeviceControl.isSameFormat(current, best))
        #expect(!DeviceControl.isSameFormat(Self.pcm(16, rate: 48_000).mFormat, best))
    }
}
