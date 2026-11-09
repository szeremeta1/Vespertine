//
// Vespertine: which rate and format a measurement microphone records in, against simulated device format lists (no
// hardware): a UMIK-1 that runs at 48 kHz measured through a DAC at 176.4 kHz was refused at the level check.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import CVespertineRT
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Room measurement microphone format")
struct RoomCaptureInputTests {
    private static func float(_ rate: Double, channels: Int = 1) -> CaptureStreamFormat {
        CaptureStreamFormat(rate: rate, channels: channels, isFloat: true, bits: 32)
    }
    private static func int(_ bits: Int, _ rate: Double, channels: Int = 1) -> CaptureStreamFormat {
        CaptureStreamFormat(rate: rate, channels: channels, isFloat: false, bits: bits)
    }

    /// A UMIK-1 as Core Audio shows it: one mono stream, virtual format Float32, rates as given.
    private static func umik(rates: [Double] = [48_000], nominal: Double = 48_000, current: CaptureStreamFormat? = nil,
                             available: [CaptureStreamFormat]? = nil, shares: Bool = false) -> CaptureInputDescription {
        let formats = available ?? rates.flatMap { [float($0), int(24, $0)] }
        return CaptureInputDescription(name: "UMIK-1", nominalRate: nominal, supportedRates: rates,
                                       streams: [.init(current: current ?? float(nominal), available: formats)], sharesDeviceWithOutput: shares)
    }

    // MARK: Rate

    @Test("A 48 kHz-only microphone records at 48 kHz whatever the output runs at (Fosi ZD3 at 176.4 kHz)")
    func umikAgainstHighRateOutput() throws {
        let plan = try CaptureInputPlanner.plan(Self.umik(), outputRate: 176_400)
        #expect(plan.captureRate == 48_000)
        #expect(!plan.changesNominalRate)
        #expect(plan.streamChanges.isEmpty)
        #expect(plan.kinds == [.float32])
    }

    @Test("A 44.1 kHz-only microphone records at 44.1 kHz")
    func umikAtFortyFour() throws {
        let plan = try CaptureInputPlanner.plan(Self.umik(rates: [44_100], nominal: 44_100), outputRate: 192_000)
        #expect(plan.captureRate == 44_100)
    }

    @Test("A microphone idling at another rate is moved to 48 kHz, to a rate it supports")
    func movedToSupported() throws {
        let plan = try CaptureInputPlanner.plan(Self.umik(rates: [16_000, 48_000, 96_000, 192_000], nominal: 192_000), outputRate: 192_000)
        #expect(plan.captureRate == 48_000)
        #expect(plan.changesNominalRate)
        let high = try CaptureInputPlanner.plan(Self.umik(rates: [96_000], nominal: 96_000), outputRate: 48_000)
        #expect(high.captureRate == 96_000)
    }

    @Test("With 44.1 and 48 kHz both on offer, the output's family decides, and 48 kHz otherwise")
    func families() throws {
        func rate(nominal: Double, output: Double) throws -> Double {
            try CaptureInputPlanner.plan(Self.umik(rates: [44_100, 48_000], nominal: nominal), outputRate: output).captureRate
        }
        #expect(try rate(nominal: 96_000, output: 176_400) == 44_100)
        #expect(try rate(nominal: 96_000, output: 88_200) == 44_100)
        #expect(try rate(nominal: 96_000, output: 192_000) == 48_000)
        #expect(try rate(nominal: 96_000, output: 96_000) == 48_000)
        // Already at 48 kHz or 44.1 kHz: left there rather than switched for tidiness.
        #expect(try rate(nominal: 48_000, output: 176_400) == 48_000)
        #expect(try rate(nominal: 44_100, output: 192_000) == 44_100)
    }

    @Test("A microphone with only low rates can't carry a 20 kHz sweep and says so")
    func tooSlow() {
        #expect(throws: CaptureInputError.noUsableRate("UMIK-1", offered: [8_000, 16_000])) {
            try CaptureInputPlanner.plan(Self.umik(rates: [8_000, 16_000], nominal: 16_000), outputRate: 48_000)
        }
        #expect(CaptureInputError.noUsableRate("UMIK-1", offered: [8_000]).errorDescription?.contains("44.1 kHz or more") == true)
    }

    @Test("An input that is the output's own device keeps its rate")
    func sharedDevice() throws {
        let plan = try CaptureInputPlanner.plan(Self.umik(rates: [44_100, 48_000, 176_400], nominal: 176_400, shares: true), outputRate: 176_400)
        #expect(plan.captureRate == 176_400)
        #expect(!plan.changesNominalRate)
    }

    // MARK: Format

    @Test("Integer-only microphones are recorded as they are and converted to Float32 in software")
    func integerOnly() throws {
        for bits in [16, 24, 32] {
            let kind: CaptureSampleKind = bits == 16 ? .int16 : bits == 24 ? .int24 : .int32
            let input = Self.umik(current: Self.int(bits, 48_000), available: [Self.int(bits, 48_000)])
            let plan = try CaptureInputPlanner.plan(input, outputRate: 176_400)
            #expect(plan.kinds == [kind], "\(bits)-bit")
            #expect(plan.streamChanges.isEmpty)
        }
    }

    @Test("A stream that isn't Float32 is put on it when it can be, else read as it is")
    func prefersFloat() throws {
        let plan = try CaptureInputPlanner.plan(Self.umik(current: Self.int(24, 48_000)), outputRate: 176_400)
        #expect(plan.streamChanges[0] == Self.float(48_000))
        #expect(plan.kinds == [.float32])
        let fixed = try CaptureInputPlanner.plan(Self.umik(current: Self.int(16, 48_000), available: [Self.int(16, 48_000), Self.int(24, 48_000)]), outputRate: 176_400)
        #expect(fixed.kinds == [.int16], "readable as it is: not changed for a wider integer")
        #expect(fixed.streamChanges.isEmpty)
    }

    @Test("Non-interleaved, 64-bit float and ranged formats are accepted")
    func otherLayouts() throws {
        let nonInterleaved = CaptureStreamFormat(rate: 48_000, channels: 2, isFloat: true, bits: 32, interleaved: false)
        #expect(nonInterleaved.sampleKind == .float32)
        let double = CaptureStreamFormat(rate: 48_000, channels: 1, isFloat: true, bits: 64)
        #expect(try CaptureInputPlanner.plan(Self.umik(current: double, available: [double]), outputRate: 48_000).kinds == [.float64])
        let ranged = CaptureStreamFormat(rateMin: 8_000, rateMax: 96_000, channels: 1, isFloat: true, bits: 32)
        let plan = try CaptureInputPlanner.plan(Self.umik(rates: [44_100, 48_000, 96_000], nominal: 96_000, current: Self.int(24, 96_000), available: [ranged]), outputRate: 192_000)
        #expect(plan.captureRate == 48_000)
        #expect(plan.streamChanges[0] == ranged)
    }

    @Test("Formats that can't be read (byte-swapped, odd widths, not PCM) are refused with a reason")
    func unreadable() {
        let swapped = CaptureStreamFormat(rate: 48_000, channels: 1, isFloat: false, bits: 24, bigEndian: true)
        let low = CaptureStreamFormat(rate: 48_000, channels: 1, isFloat: false, bits: 32, alignedHigh: false)
        let compressed = CaptureStreamFormat(rate: 48_000, channels: 1, isFloat: false, bits: 16, isLinearPCM: false)
        for format in [swapped, low, compressed] {
            #expect(format.sampleKind == nil)
            #expect(throws: CaptureInputError.noUsableFormat("UMIK-1", rate: 48_000)) {
                try CaptureInputPlanner.plan(Self.umik(current: format, available: [format]), outputRate: 176_400)
            }
        }
    }

    @Test("Several streams and channels (a multi-channel interface) each get a reader")
    func multiChannel() throws {
        let input = CaptureInputDescription(
            name: "Interface", nominalRate: 48_000, supportedRates: [44_100, 48_000],
            streams: [.init(current: Self.int(24, 48_000, channels: 2), available: [Self.int(24, 48_000, channels: 2), Self.float(48_000, channels: 2)]),
                      .init(current: Self.float(48_000, channels: 4), available: [Self.float(48_000, channels: 4)])])
        let plan = try CaptureInputPlanner.plan(input, outputRate: 96_000)
        #expect(plan.kinds == [.float32, .float32])
        #expect(plan.streamChanges.keys.sorted() == [0])
        #expect(throws: CaptureInputError.noStreams("None")) {
            try CaptureInputPlanner.plan(CaptureInputDescription(name: "None", nominalRate: 48_000, supportedRates: [48_000], streams: []), outputRate: 48_000)
        }
    }

    @Test("A format from the HAL's description maps the same way")
    func fromASBD() {
        var d = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
                                            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        #expect(CaptureStreamFormat(d).sampleKind == .float32)
        d.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        d.mBitsPerChannel = 24
        d.mBytesPerFrame = 3
        #expect(CaptureStreamFormat(d).sampleKind == .int24)
        d.mFormatFlags = kAudioFormatFlagIsPacked
        #expect(CaptureStreamFormat(d).sampleKind == nil, "unsigned integer")
    }

    @Test("An aggregate device that lists no formats is recorded as it is, at a rate it offers")
    func aggregateWithoutFormatList() throws {
        // Aggregates often hide their format list; the stream follows the device's rate and keeps its format.
        let input = Self.umik(rates: [44_100, 48_000, 96_000], nominal: 96_000, current: Self.float(96_000), available: [])
        let plan = try CaptureInputPlanner.plan(input, outputRate: 192_000)
        #expect(plan.captureRate == 48_000)
        #expect(plan.changesNominalRate)
        #expect(plan.streamChanges.isEmpty)
        #expect(plan.kinds == [.float32])
        let odd = CaptureStreamFormat(rate: 96_000, channels: 1, isFloat: false, bits: 24, bigEndian: true)
        #expect(throws: CaptureInputError.self) { try CaptureInputPlanner.plan(Self.umik(rates: [48_000], nominal: 96_000, current: odd, available: []), outputRate: 48_000) }
    }

    @Test("A Float32 stream left at another rate is moved to the recording's (the loopback and shared-device case)")
    func staleStreamRate() throws {
        let input = Self.umik(rates: [48_000], nominal: 48_000, current: Self.float(44_100), available: [Self.float(44_100), Self.float(48_000)], shares: true)
        let plan = try CaptureInputPlanner.plan(input, outputRate: 48_000)
        #expect(plan.captureRate == 48_000)
        #expect(plan.streamChanges[0] == Self.float(48_000))
    }

    // MARK: Stimulus at the output's rate

    @Test("A 48 kHz stimulus played by a 176.4 kHz output keeps its length, level and pitch")
    func stimulusConversion() throws {
        let n = 48_000
        let tone = (0..<n).map { Float(0.5 * sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
        let out = try #require(RoomStimulusRate.convert(tone, from: 48_000, to: 176_400))
        #expect(out.count == 176_400)
        let middle = out[44_100..<132_300]
        #expect(abs(Double(middle.map { abs($0) }.max() ?? 0) - 0.5) < 0.01)
        let crossings = zip(middle, middle.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        #expect(abs(crossings - 500) <= 1, "1 kHz over 0.5 s: \(crossings) cycles")
        #expect(RoomStimulusRate.convert(tone, from: 48_000, to: 48_000) == tone)
    }

    @Test("A capture made with a 48 kHz microphone through a 176.4 kHz output is aligned and analysed")
    func sweepSurvivesTheRateChange() throws {
        let layout = try RoomCaptureLayout(sampleRate: 48_000, sweepDuration: 2)
        let played = layout.stimulus()
        let atOutput = try #require(RoomStimulusRate.convert(played, from: 48_000, to: 176_400))
        // The room: 7.3 ms of travel at the output's rate and a little attenuation; the microphone then takes it at 48 kHz.
        let travel = Int((0.0073 * 176_400).rounded())
        let heard = [Float](repeating: 0, count: travel) + atOutput.map { $0 * 0.1 }
        let recorded = try #require(RoomStimulusRate.convert(heard, from: 176_400, to: 48_000))
        let frames = Array(recorded.prefix(layout.recordingFrames))
        let request = RoomCaptureRequest(inputDevice: 1, outputDevice: 2, inputChannel: 0, outputChannel: 0, layout: layout)
        let recording = RoomRecording(samples: frames, sampleRate: 48_000, request: request, startedAt: Date(), surplusFrames: 0)
        let assessment = RoomCaptureAssessment.assess(recording, limits: RoomQualityLimits())
        #expect(assessment.accepted, "\(assessment.rejections)")
        #expect(abs(assessment.metrics.driftPPM ?? 1_000) < 50, "drift \(assessment.metrics.driftPPM ?? .nan) ppm")
    }

    // MARK: The capture's conversion to Float32

    /// Runs the real capture IOProc on one buffer of `bytes` and returns the interleaved Float32 it wrote to the ring.
    private func capture(kind: CaptureSampleKind, channels: UInt32, frames: Int, bytes: [UInt8]) throws -> [Float] {
        let ring = try #require(nrt_ring_create(4_096, channels))
        defer { nrt_ring_destroy(ring) }
        let capture = try #require(nrt_capture_create(ring, 1_024))
        defer { nrt_capture_destroy(capture) }
        nrt_capture_set_kind(capture, 0, kind.rawValue)
        var data = bytes
        var out = [Float](repeating: -9, count: frames * Int(channels))
        data.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            var now = AudioTimeStamp(), input = AudioTimeStamp(), output = AudioTimeStamp(), unused = AudioBufferList()
            _ = nrt_capture_ioproc(1, &now, &list, &input, &unused, &output, UnsafeMutableRawPointer(capture))
        }
        #expect(nrt_ring_read(ring, &out, UInt32(frames)) == UInt32(frames))
        return out
    }

    private func le(_ values: [Int32], bytes: Int) -> [UInt8] {
        values.flatMap { v in (0..<bytes).map { UInt8(truncatingIfNeeded: UInt32(bitPattern: v) >> (8 * UInt32($0))) } }
    }

    @Test("The capture converts 16-, 24- and 32-bit integer and 64-bit float samples to Float32")
    func ioprocConverts() throws {
        let i16 = try capture(kind: .int16, channels: 1, frames: 4, bytes: le([0, 16_384, -32_768, 32_767], bytes: 2))
        #expect(i16 == [0, 0.5, -1, Float(32_767) / 32_768])
        let i24 = try capture(kind: .int24, channels: 1, frames: 4, bytes: le([0, 4_194_304, -8_388_608, 8_388_607], bytes: 3))
        #expect(i24 == [0, 0.5, -1, Float(8_388_607) / 8_388_608])
        let i32 = try capture(kind: .int32, channels: 1, frames: 3, bytes: le([0, 1 << 30, Int32.min], bytes: 4))
        #expect(i32 == [0, 0.5, -1])
        var doubles: [UInt8] = []
        for v in [0.25, -0.5] as [Double] { withUnsafeBytes(of: v) { doubles += $0 } }
        #expect(try capture(kind: .float64, channels: 1, frames: 2, bytes: doubles) == [0.25, -0.5])
        var floats: [UInt8] = []
        for v in [0.125, -0.75] as [Float] { withUnsafeBytes(of: v) { floats += $0 } }
        #expect(try capture(kind: .float32, channels: 1, frames: 2, bytes: floats) == [0.125, -0.75])
    }

    @Test("Interleaved integer channels stay in order")
    func ioprocInterleaves() throws {
        // Two channels, three frames: L = 0.5, 0.25, 0 ; R = -0.5, -0.25, -1.
        let out = try capture(kind: .int16, channels: 2, frames: 3, bytes: le([16_384, -16_384, 8_192, -8_192, 0, -32_768], bytes: 2))
        #expect(out == [0.5, -0.5, 0.25, -0.25, 0, -1])
    }
}
