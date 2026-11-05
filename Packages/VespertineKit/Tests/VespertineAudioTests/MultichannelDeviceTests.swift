//
// Vespertine — multichannel music on a multichannel output, channel for channel: what the engine's own pieces hand the
// device (FormatPlanner → decoder → Decoding → ring → the I/O proc's render), for 3 to 16 channels on an output with
// more channels than the file (a 16-channel interface, an HDMI receiver), in one interleaved buffer and spread over
// several streams. Every sample carries its channel's number, so each output's source, order and bit-exactness is read
// straight from what the device got.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import CoreAudio
import CVespertineRT
import Foundation
import Testing
@testable import VespertineAudio
import VespertineTestSupport

/// A signal that names itself: sample `i` of channel `c` is the 24-bit word `(c + 1) << 18 | i mod 2^18`, so any sample
/// says which source channel it came from and where in the file it sits, and survives Float32 exactly.
enum ChannelID {
    static let shift = 18
    static let scale = Float(1 << 23)

    static func word(channel: Int, frame: Int) -> Int32 { Int32((channel + 1) << shift | (frame & ((1 << shift) - 1))) }

    /// (source channel, frame mod 2^18) of a device sample; nil for anything not exactly one of ours (silence included).
    static func decode(_ sample: Float) -> (channel: Int, frame: Int)? {
        let scaled = sample * scale
        guard scaled == scaled.rounded(), scaled >= Float(1 << shift) else { return nil }
        let v = Int(scaled)
        return ((v >> shift) - 1, v & ((1 << shift) - 1))
    }

    /// WAVE_FORMAT_EXTENSIBLE, 24-bit, with `mask` (0: no speaker positions), `channels` × `frames` of the signal.
    static func writeWAV(to url: URL, channels: Int, frames: Int, rate: Double, mask: UInt32) throws {
        try writeWAV(to: url, channels: channels, frames: frames, rate: rate, mask: mask) { c, f in word(channel: c, frame: f) }
    }

    /// The same container for any 24-bit signal: `sample(channel, frame)`.
    static func writeWAV(to url: URL, channels: Int, frames: Int, rate: Double, mask: UInt32, sample: (Int, Int) -> Int32) throws {
        var data = Data()
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let blockAlign = channels * 3, bytes = frames * blockAlign
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(4 + 8 + 40 + 8 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(40)
        u16(0xFFFE); u16(channels); u32(UInt32(rate)); u32(UInt32(Int(rate) * blockAlign)); u16(blockAlign); u16(24)
        u16(22); u16(24); u32(mask)
        // KSDATAFORMAT_SUBTYPE_PCM
        data.append(contentsOf: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(bytes))
        data.reserveCapacity(data.count + bytes)
        for f in 0..<frames {
            for c in 0..<channels {
                let w = UInt32(bitPattern: sample(c, f))
                data.append(contentsOf: [UInt8(w & 0xFF), UInt8(w >> 8 & 0xFF), UInt8(w >> 16 & 0xFF)])
            }
        }
        try data.write(to: url)
    }

    /// What each device channel carried, over `frames` interleaved frames of `stride` channels: the one source channel it
    /// carried throughout, -1 for silence throughout, nil when it was anything else (mixed, altered, out of order).
    /// `firstFrame`: the source frame the capture starts at (nil: whatever the first sample says).
    static func identify(_ interleaved: [Float], stride: Int, frames: Int, firstFrame: Int? = nil) -> [Int?] {
        (0..<stride).map { o in
            var channel: Int?? = .none
            var expected = firstFrame
            for f in 0..<frames {
                let s = interleaved[f * stride + o]
                if s == 0 {
                    if case .some(let c) = channel, c != -1 { return nil }
                    channel = .some(-1)
                    continue
                }
                guard let (c, at) = decode(s) else { return nil }
                if case .some(let was) = channel, was != c { return nil }
                channel = .some(c)
                if let e = expected, at != e & ((1 << shift) - 1) { return nil }
                expected = at + 1
            }
            return channel ?? -1
        }
    }
}

/// WAVE speaker-mask bits.
enum WaveMask {
    static let FL: UInt32 = 0x1, FR: UInt32 = 0x2, FC: UInt32 = 0x4, LFE: UInt32 = 0x8, BL: UInt32 = 0x10, BR: UInt32 = 0x20
    static let FLC: UInt32 = 0x40, FRC: UInt32 = 0x80, BC: UInt32 = 0x100, SL: UInt32 = 0x200, SR: UInt32 = 0x400
    static let TC: UInt32 = 0x800, TFL: UInt32 = 0x1000, TFC: UInt32 = 0x2000, TFR: UInt32 = 0x4000
    static let TBL: UInt32 = 0x8000, TBC: UInt32 = 0x1_0000, TBR: UInt32 = 0x2_0000
}

@Suite("Multichannel to a multichannel output, channel for channel")
struct MultichannelDeviceTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let channels: Int
        let mask: UInt32
        /// The source channel each device output carries (outputs past these are silent).
        let carries: [Int]
        var testDescription: String { name }
        init(_ name: String, channels: Int, mask: UInt32, carries: [Int]? = nil) {
            self.name = name
            self.channels = channels
            self.mask = mask
            self.carries = carries ?? Array(0..<channels)
        }
    }

    static let w = WaveMask.self
    static let cases: [Case] = [
        Case("3.0 L R C", channels: 3, mask: w.FL | w.FR | w.FC),
        Case("quad (FL FR BL BR)", channels: 4, mask: w.FL | w.FR | w.BL | w.BR),
        Case("5.1 (back pair, WAV 0x3F)", channels: 6, mask: 0x3F),
        Case("5.1 (side pair, WAV 0x60F)", channels: 6, mask: 0x60F),
        Case("5.1 with no speaker mask", channels: 6, mask: 0),
        // WAV order is FL FR FC LFE BL BR SL SR; the standard 7.1 order puts the side pair (Ls Rs) before the back pair.
        Case("7.1 (WAV 0x63F)", channels: 8, mask: 0x63F, carries: [0, 1, 2, 3, 6, 7, 4, 5]),
        Case("7.1 with no speaker mask", channels: 8, mask: 0, carries: [0, 1, 2, 3, 6, 7, 4, 5]),
        // Above 8 channels there is no standard order: every channel goes out in the file's own order.
        Case("5.1.4 (10 ch)", channels: 10, mask: 0x3F | w.TFL | w.TFR | w.TBL | w.TBR),
        Case("7.1.4 (12 ch)", channels: 12, mask: 0x63F | w.TFL | w.TFR | w.TBL | w.TBR),
        Case("12 ch with no speaker mask", channels: 12, mask: 0),
        Case("16 ch with no speaker mask", channels: 16, mask: 0),
    ]

    /// A 16-channel interface with no speaker setup (BlackHole 16ch, a multichannel USB DAC or an HDMI output as macOS
    /// shows it before Configure Speakers), 24-bit, 44.1 to 192 kHz.
    static func device(channels: Int = 16) -> GoldenRender.Device {
        let rates = GoldenDevices.rates
        return GoldenRender.Device(name: "\(channels)-channel interface",
                                   capabilities: DeviceCapabilities(sampleRates: rates, physicalFormats: [
                                       PhysicalFormat(minRate: rates.min()!, maxRate: rates.max()!, bitDepth: 24, isInteger: true,
                                                      isMixable: true, channels: channels)], outputChannels: channels, supportsDoP: false),
                                   streamChannels: channels)
    }

    private func tmp(_ name: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("mcdev-\(UUID())-\(name)") }

    @Test("Every channel reaches its own output of a 16-channel device, bit for bit, in order, nothing downmixed; the rest silent",
          arguments: cases)
    func channelForChannel(_ c: Case) throws {
        let url = tmp("\(c.channels).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = 12_000
        try ChannelID.writeWAV(to: url, channels: c.channels, frames: frames, rate: 96_000, mask: c.mask)
        let device = Self.device()
        let output = try GoldenRender.render([PlayableItem(url: url)], device: device)
        let session = try #require(output.sessions.first)
        #expect(output.sessions.count == 1)
        #expect(session.plan.deviceSampleRate == 96_000, "device rate \(session.plan.deviceSampleRate)")
        #expect(!session.plan.resamples)
        #expect(session.plan.channels == c.channels && session.plan.spatial == .off)
        #expect(session.frames == frames)
        let samples = session.words.map { Float(bitPattern: $0) }
        let carried = ChannelID.identify(samples, stride: device.streamChannels, frames: session.frames, firstFrame: 0)
        let want: [Int?] = c.carries + Array(repeating: -1, count: device.streamChannels - c.channels)
        #expect(carried == want, "\(c.name): outputs carried \(carried.map { $0.map(String.init) ?? "✗" })")
    }

    @Test("A 5.1 file to a 6-channel device spread over three stereo streams: each stream gets its own pair")
    func multiStream() throws {
        // The I/O proc's general case (several buffers: aggregates, receivers that show 2-channel streams).
        let channels = 6, frames = 2048
        let ring = try #require(nrt_ring_create(8192, UInt32(channels)))
        defer { nrt_ring_destroy(ring) }
        let context = try #require(nrt_context_create(ring, 4096))
        defer { nrt_context_destroy(context) }
        var interleaved = [Float](repeating: 0, count: frames * channels)
        for f in 0..<frames { for ch in 0..<channels { interleaved[f * channels + ch] = Float(ChannelID.word(channel: ch, frame: f)) / ChannelID.scale } }
        _ = interleaved.withUnsafeBufferPointer { nrt_ring_write(ring, $0.baseAddress!, UInt32(frames)) }

        for layout in [[2, 2, 2], [1, 1, 1, 1, 1, 1], [4, 4]] {
            let deviceChannels = layout.reduce(0, +)
            let n = 512
            let list = AudioBufferList.allocate(maximumBuffers: layout.count)
            defer { for b in list { free(b.mData) }; free(list.unsafeMutablePointer) }
            for (i, ch) in layout.enumerated() {
                list[i] = AudioBuffer(mNumberChannels: UInt32(ch), mDataByteSize: UInt32(n * ch * 4), mData: calloc(n * ch, 4))
            }
            var now = AudioTimeStamp()
            var noInput = AudioBufferList()
            _ = nrt_device_ioproc(0, &now, &noInput, &now, list.unsafeMutablePointer, &now, UnsafeMutableRawPointer(context))
            // Re-interleave the device's view: channel k of the device is the k-th channel across the streams in order.
            var device = [Float](repeating: 0, count: n * deviceChannels)
            var base = 0
            for (i, ch) in layout.enumerated() {
                let p = list[i].mData!.assumingMemoryBound(to: Float.self)
                for f in 0..<n { for c in 0..<ch { device[f * deviceChannels + base + c] = p[f * ch + c] } }
                base += ch
            }
            let carried = ChannelID.identify(device, stride: deviceChannels, frames: n)
            let want: [Int?] = (0..<deviceChannels).map { $0 < channels ? $0 : -1 }
            #expect(carried == want, "streams \(layout): \(carried)")
        }
    }

    @Test("A mono file on a multichannel device plays on L and R, nothing else; stereo on the first pair only")
    func monoAndStereo() throws {
        for channels in [1, 2] {
            let url = tmp("\(channels).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            try ChannelID.writeWAV(to: url, channels: channels, frames: 4800, rate: 48_000, mask: channels == 1 ? WaveMask.FC : WaveMask.FL | WaveMask.FR)
            let device = Self.device()
            let session = try #require(try GoldenRender.render([PlayableItem(url: url)], device: device).sessions.first)
            let carried = ChannelID.identify(session.words.map { Float(bitPattern: $0) }, stride: 16, frames: session.frames, firstFrame: 0)
            let want: [Int?] = (channels == 1 ? [0, 0] : [0, 1]) + Array(repeating: -1, count: 14)
            #expect(carried == want, "\(channels) ch: \(carried)")
            #expect(session.plan.deviceSampleRate == 48_000)
        }
    }

    @Test("Back-to-back multichannel files of different layouts and the same channel count each land on their own outputs")
    func sameCountDifferentLayout() throws {
        // Joined on one session (the plans are device-compatible): the second file must not inherit the first one's map.
        let a = tmp("a.wav"), b = tmp("b.wav")
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        try ChannelID.writeWAV(to: a, channels: 8, frames: 4800, rate: 48_000, mask: 0x63F)
        try ChannelID.writeWAV(to: b, channels: 8, frames: 4800, rate: 48_000, mask: 0x3F | WaveMask.FLC | WaveMask.FRC)
        let device = Self.device(channels: 8)
        let output = try GoldenRender.render([PlayableItem(url: a), PlayableItem(url: b)], device: device)
        let session = try #require(output.sessions.first)
        let samples = session.words.map { Float(bitPattern: $0) }
        let first = ChannelID.identify(Array(samples.prefix(4800 * 8)), stride: 8, frames: 4800, firstFrame: 0)
        let second = ChannelID.identify(Array(samples.dropFirst(4800 * 8)), stride: 8, frames: 4800, firstFrame: 0)
        #expect(first == [0, 1, 2, 3, 6, 7, 4, 5], "7.1: \(first)")
        // 7.1 wide (FLC/FRC): L R C LFE Ls Rs Lc Rc in WAV order, every channel in place.
        #expect(second == [0, 1, 2, 3, 4, 5, 6, 7], "7.1 wide: \(second)")
    }
}

@Suite("Multichannel to a configured speaker setup (Audio MIDI Setup › Configure Speakers, HDMI receivers)")
struct SpeakerSetupDeviceTests {
    static let (L, R, C, LFE, Ls, Rs, Lrs, Rrs) = (kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                                                 kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
                                                 kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight)

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let channels: Int
        let mask: UInt32
        let speakers: [AudioChannelLabel]
        /// The source channel each speaker output carries (-1: silent, nil: a mix of several).
        let carries: [Int?]
        var testDescription: String { name }
    }

    static let mpeg71: [AudioChannelLabel] = [L, R, C, LFE, Ls, Rs, Lrs, Rrs]
    /// CEA-861 order, as HDMI receivers often report it: L R LFE C Ls Rs Lrs Rrs.
    static let hdmi71: [AudioChannelLabel] = [L, R, LFE, C, Ls, Rs, Lrs, Rrs]
    static let mpeg51: [AudioChannelLabel] = [L, R, C, LFE, Ls, Rs]

    static let cases: [Case] = [
        Case(name: "5.1 (WAV 0x3F) on 7.1 speakers", channels: 6, mask: 0x3F, speakers: mpeg71, carries: [0, 1, 2, 3, 4, 5, -1, -1]),
        Case(name: "5.1 (no mask) on 7.1 speakers", channels: 6, mask: 0, speakers: mpeg71, carries: [0, 1, 2, 3, 4, 5, -1, -1]),
        Case(name: "7.1 (WAV 0x63F) on 7.1 speakers", channels: 8, mask: 0x63F, speakers: mpeg71, carries: [0, 1, 2, 3, 6, 7, 4, 5]),
        Case(name: "7.1 (no mask) on 7.1 speakers", channels: 8, mask: 0, speakers: mpeg71, carries: [0, 1, 2, 3, 6, 7, 4, 5]),
        Case(name: "5.1 (WAV 0x3F) on 7.1 speakers in HDMI order", channels: 6, mask: 0x3F, speakers: hdmi71, carries: [0, 1, 3, 2, 4, 5, -1, -1]),
        Case(name: "5.1 (no mask) on 7.1 speakers in HDMI order", channels: 6, mask: 0, speakers: hdmi71, carries: [0, 1, 3, 2, 4, 5, -1, -1]),
        Case(name: "7.1 (WAV 0x63F) on 7.1 speakers in HDMI order", channels: 8, mask: 0x63F, speakers: hdmi71, carries: [0, 1, 3, 2, 6, 7, 4, 5]),
        Case(name: "5.1 (no mask) on 5.1 speakers", channels: 6, mask: 0, speakers: mpeg51, carries: [0, 1, 2, 3, 4, 5]),
        Case(name: "quad (FL FR BL BR) on 5.1 speakers", channels: 4, mask: 0x33, speakers: mpeg51, carries: [0, 1, -1, -1, 2, 3]),
        // Folded (a speaker for every channel there isn't): front four untouched, the surrounds carry a mix (nil), nothing silent.
        Case(name: "7.1 (no mask) folded into 5.1 speakers", channels: 8, mask: 0, speakers: mpeg51, carries: [0, 1, 2, 3, nil, nil]),
        Case(name: "7.1 (WAV 0x63F) folded into 5.1 speakers", channels: 8, mask: 0x63F, speakers: mpeg51, carries: [0, 1, 2, 3, nil, nil]),
        // 5.1.2 (FFmpeg: FL FR FC LFE SL SR TFL TFR) into 5.1: Apple's converter played it as silence. The heights join L and R.
        Case(name: "5.1.2 folded into 5.1 speakers", channels: 8, mask: 0x60F | 0x1000 | 0x4000, speakers: mpeg51, carries: [nil, nil, 2, 3, 4, 5]),
        // 7.1.4 into 7.1: the tops join the fronts and the backs; every other channel untouched.
        Case(name: "7.1.4 folded into 7.1 speakers", channels: 12, mask: 0x63F | 0x1000 | 0x4000 | 0x8000 | 0x2_0000, speakers: mpeg71,
             carries: [nil, nil, 2, 3, 6, 7, nil, nil]),
        // A setup named the WAVE way (back pair Ls/Rs beside a side pair Lsd/Rsd) takes a WAV 7.1 as it is.
        Case(name: "7.1 (WAV 0x63F) on 7.1 speakers named the WAVE way", channels: 8, mask: 0x63F,
             speakers: [L, R, C, LFE, Ls, Rs, kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RightSurroundDirect], carries: Array(0..<8)),
        Case(name: "7.1 (no mask) on 7.1 speakers named the WAVE way", channels: 8, mask: 0,
             speakers: [L, R, C, LFE, Ls, Rs, kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RightSurroundDirect], carries: Array(0..<8)),
    ]

    @Test("A driver's placeholder layout (channel n named label n) is no speaker setup; a real one is")
    func placeholder() throws {
        let numbered = try #require(ChannelLayouts.layout(labels: (1...16).map { AudioChannelLabel($0) }))
        #expect(ChannelLayouts.isPlaceholder(numbered))
        #expect(ChannelLayouts.isPlaceholder(try #require(ChannelLayouts.layout(labels: (1...8).map { AudioChannelLabel($0) }))))
        #expect(!ChannelLayouts.isPlaceholder(try #require(ChannelLayouts.layout(labels: Self.hdmi71))))
        #expect(!ChannelLayouts.isPlaceholder(try #require(ChannelLayouts.layout(labels: Self.mpeg71))))
        #expect(!ChannelLayouts.isPlaceholder(try #require(ChannelLayouts.layout(labels: [Self.L, Self.R]))))
    }

    @Test("DoP and bitstream are never folded: their words are copied, never mixed")
    func noFoldOutsidePCM() throws {
        let input = try #require(AudioFormats.float32(sampleRate: 176_400, channels: 8, interleaved: true,
                                                      layout: ChannelLayouts.layout(labels: Self.mpeg71)))
        let room = try #require(ChannelLayouts.layout(labels: Self.mpeg51))
        var plan = OutputPlan(mode: .pcm, deviceSampleRate: 176_400, decodedSampleRate: 176_400, physicalBitDepth: 24, channels: 6,
                              dsdConvertedToPCM: false, reason: "")
        #expect(OutputSession.speakerFold(from: input, to: room, plan: plan) != nil, "PCM 7.1 into 5.1 folds")
        for mode in [OutputPlan.Mode.dop, .bitstream] {
            plan.mode = mode
            #expect(OutputSession.speakerFold(from: input, to: room, plan: plan) == nil, "\(mode) must not be mixed")
        }
    }

    @Test("A fold keeps each channel that has its own speaker bit for bit and puts the others at -3 dB on the nearest")
    func foldGains() throws {
        let source: [AudioChannelLabel] = [Self.L, Self.R, Self.C, Self.LFE, Self.Ls, Self.Rs, Self.Lrs, Self.Rrs]
        let router = try #require(BedRouter(source: source, bed: Self.mpeg51, foldGain: Float(0.5.squareRoot())))
        #expect(router.dropped == 0)
        for s in 0..<6 { #expect(router.routes[s].count == 1 && router.routes[s][0].bed == s && router.routes[s][0].gain == 1) }
        #expect(router.routes[6].map(\.bed) == [4] && abs(router.routes[6][0].gain - 0.70710677) < 1e-6)
        #expect(router.routes[7].map(\.bed) == [5] && abs(router.routes[7][0].gain - 0.70710677) < 1e-6)
        // A centre with no centre speaker: equal power between L and R (no further -3 dB).
        let lr = try #require(BedRouter(source: [Self.L, Self.R, Self.C], bed: [Self.L, Self.R, Self.Ls, Self.Rs], foldGain: Float(0.5.squareRoot())))
        #expect(lr.routes[2].map(\.bed) == [0, 1] && lr.routes[2].allSatisfy { abs($0.gain - 0.70710677) < 1e-6 })
    }

    @Test("Each channel reaches its own speaker, bit for bit, whatever order the device names them in", arguments: cases)
    func placed(_ c: Case) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spk-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = 9600
        try ChannelID.writeWAV(to: url, channels: c.channels, frames: frames, rate: 48_000, mask: c.mask)
        let speakers = try #require(ChannelLayouts.layout(labels: c.speakers))
        let device = DeviceCapabilities(sampleRates: GoldenDevices.rates, physicalFormats: [
            PhysicalFormat(minRate: 44_100, maxRate: 192_000, bitDepth: 24, isInteger: true, isMixable: true, channels: 8)],
            outputChannels: 8, supportsDoP: false, speakerLayoutChannels: c.speakers.count)
        let probed = try SourceOpener.probe(url)
        var plan = FormatPlanner.plan(source: probed.format, device: device)
        plan.integerSamples = false
        #expect(plan.channels == c.speakers.count && plan.spatial == .off)
        // OutputSession.init: the device's own speaker layout is what the stream is converted to.
        let layout = try #require(OutputSession.routeLayout(plan: plan, speakers: speakers))
        #expect(layout.channelLabels == c.speakers)
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: url))
        let path = SignalPath(source: probed.format, decoderName: "test", plan: plan,
                              applied: AppliedFormat(sampleRate: 48_000, physicalBitDepth: 24, physicalIsInteger: true, virtualChannels: 8,
                                                     exclusive: true, bufferFrames: 512),
                              deviceName: "Receiver", deviceUID: "test",
                              deviceProfile: DeviceProfile(kind: .usbDAC, tag: "", canBeBitPerfect: true, symbol: "x"), volume: .fixed)
        let decoding = try Decoding(item: PlayableItem(url: url), probed: probed, decoder: decoder, path: path, chunk: 4096, layout: layout)
        var out: [Float] = []
        while true {
            let chunk = decoding.convertChunk()
            if let data = chunk.data { out += UnsafeBufferPointer(start: data, count: Int(chunk.frames) * plan.channels) }
            if chunk.ended { break }
        }
        let n = plan.channels
        let carried = ChannelID.identify(out, stride: n, frames: out.count / n, firstFrame: 0)
        #expect(out.count / n == frames)
        #expect(carried == c.carries, "\(c.name): \(carried.map { $0.map(String.init) ?? "✗" }) on \(layout.shortNames)")
    }
}

@Suite("Spatial Audio on the I/O thread")
struct SpatialIOProcTests {
    /// Interleaved 5.1 at -20 dBFS, one tone per channel (SpatialProbe's).
    static func fiveOne(frames: Int, rate: Double) -> (samples: [Float], tones: [Double]) {
        let tones = SpatialProbe.frequencies(["FL", "FR", "FC", "LFE", "BL", "BR"])
        var s = [Float](repeating: 0, count: frames * 6)
        for f in 0..<frames { for c in 0..<6 { s[f * 6 + c] = Float(0.1 * sin(2 * .pi * tones[c] * Double(f) / rate)) } }
        return (s, tones)
    }

    @Test("The renderer runs inside the I/O proc: binaural on the first pair, every other output of the device silent",
          arguments: [2, 8, 16])
    func ioproc(deviceChannels: Int) throws {
        let rate = 48_000.0, frames = 48_000, slice = 512
        let bed = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A))
        let renderer = try SpatialRenderer(inputLayout: bed, channels: 6, sampleRate: rate, maxFrames: 4096, mode: .headTracked)
        let ring = try #require(nrt_ring_create(65_536, 6))
        defer { nrt_ring_destroy(ring) }
        let context = try #require(nrt_context_create(ring, 4096))
        defer { nrt_context_destroy(context) }
        #expect(renderer.attach(to: context))
        let (source, tones) = Self.fiveOne(frames: frames, rate: rate)
        _ = source.withUnsafeBufferPointer { nrt_ring_write(ring, $0.baseAddress!, UInt32(frames)) }
        var out: [Float] = []
        var buffer = [Float](repeating: 0, count: slice * deviceChannels)
        for _ in 0..<(frames / slice) {
            buffer.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(deviceChannels),
                                                                                    mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                var now = AudioTimeStamp()
                var noInput = AudioBufferList()
                _ = nrt_device_ioproc(0, &now, &noInput, &now, &list, &now, UnsafeMutableRawPointer(context))
            }
            out += buffer
        }
        let n = out.count / deviceChannels
        for ch in 2..<deviceChannels { #expect((0..<n).allSatisfy { out[$0 * deviceChannels + ch] == 0 }, "output \(ch + 1) isn't silent") }
        for (c, tone) in tones.enumerated() {
            let l = SpatialProbe.level(out, stride: deviceChannels, offset: 0, frequency: tone, rate: rate, from: 9600, count: 28_800)
            let r = SpatialProbe.level(out, stride: deviceChannels, offset: 1, frequency: tone, rate: rate, from: 9600, count: 28_800)
            #expect(max(l, r) > 0.1 * 0.03, "channel \(c) not heard after Spatial Audio on a \(deviceChannels)-channel device")
        }
    }

    @Test("Multichannel files with no standard layout (above 8 channels, no speaker names) are heard on headphones",
          arguments: [10, 12, 16])
    func unlabeledAbove8(channels: Int) throws {
        let source = SourceFormat(encoding: .pcm, codec: "WAV", sampleRate: 48_000, bitDepth: 24, channels: channels)
        let headphones = DeviceCapabilities(sampleRates: [48_000], physicalFormats: [], outputChannels: 2, supportsDoP: false)
        let plan = FormatPlanner.plan(source: source, device: headphones, spatial: .headTracked)
        #expect(plan.spatial == .headTracked && plan.deviceChannels == 2)
        let bed = try #require(OutputSession.routeLayout(plan: plan, speakers: nil))
        let n = Int(bed.channelCount)
        let renderer = try SpatialRenderer(inputLayout: bed, channels: n, sampleRate: 48_000, maxFrames: 4096, mode: .fixed)
        // Each channel alone, as Decoding hands it to the ring (BedRouter when the plan has a bed).
        let labels = ChannelLayouts.wavOrderLabels(channels: channels)
        let router = plan.spatialBed == nil ? nil : labels.flatMap { BedRouter(source: $0, bed: bed.channelLabels) }
        var silent: [Int] = []
        for c in 0..<channels {
            let frames = 24_000
            var input = [Float](repeating: 0, count: frames * channels)
            for f in 0..<frames { input[f * channels + c] = Float(0.1 * sin(2 * .pi * 500 * Double(f) / 48_000)) }
            var placed = [Float](repeating: 0, count: frames * n)
            if let router { input.withUnsafeBufferPointer { router.route($0.baseAddress!, into: &placed, frames: frames) } }
            else { placed = input }
            let out = renderer.render(interleaved: placed, frames: frames)
            let level = max(SpatialProbe.level(out, stride: 2, offset: 0, frequency: 500, rate: 48_000, from: 4800, count: 14_400),
                            SpatialProbe.level(out, stride: 2, offset: 1, frequency: 500, rate: 48_000, from: 4800, count: 14_400))
            if level < 0.1 * 0.03 { silent.append(c + 1) }
        }
        #expect(silent.isEmpty, "\(channels) ch on \(bed.shortNames): channels \(silent) silent after Spatial Audio")
    }
}

@Suite("Unlabeled multichannel: one convention on every output")
struct UnlabeledConventionTests {
    @Test("A file with no speaker names puts each channel on the same speaker on headphones as on speakers", arguments: [6, 7, 8, 10, 12, 14, 16])
    func sameOnHeadphonesAndSpeakers(channels: Int) throws {
        let source = SourceFormat(encoding: .pcm, codec: "WAV", sampleRate: 48_000, bitDepth: 24, channels: channels)
        let headphones = DeviceCapabilities(sampleRates: [48_000], physicalFormats: [], outputChannels: 2, supportsDoP: false)
        let plan = FormatPlanner.plan(source: source, device: headphones, spatial: .fixed)
        let bed = try #require(OutputSession.routeLayout(plan: plan, speakers: nil))
        let labels = try #require(ChannelLayouts.wavOrderLabels(channels: channels))
        let router = try #require(BedRouter(source: labels, bed: bed.channelLabels))
        #expect(router.dropped == 0, "\(channels) ch: \(router.dropped) channels have no place on \(bed.shortNames)")
        // On a configured speaker setup of the bed's own layout, each channel goes to the speaker it has on the bed (9.1.x has no
        // bed of its own: its wides are placed between neighbours, checked above).
        guard router.approximated == 0 else { return }
        let map = try #require(ChannelLayouts.speakerMap(source: labels, outputs: bed.channelLabels), "\(channels) ch on \(bed.shortNames)")
        for (s, routes) in router.routes.enumerated() where routes.count == 1 {
            #expect(map[routes[0].bed] == s, "\(channels) ch: channel \(s + 1) is \(bed.shortNames[routes[0].bed]) on headphones, output \(map.firstIndex(of: s).map { $0 + 1 } ?? -1) on speakers")
        }
    }
}

/// Which tone each device output carries (DSD isn't bit-exact through DSD→PCM, so its channels are told apart by tone).
enum ToneID {
    /// Per output: the index of the one tone it carries (others at least 20 dB down), -1 silent, -2 several or none.
    static func identify(_ interleaved: [Float], stride: Int, tones: [Double], rate: Double, from: Int, count: Int) -> [Int] {
        (0..<stride).map { o in
            let peak = (from..<(from + count)).map { abs(interleaved[$0 * stride + o]) }.max() ?? 0
            if peak < 1e-5 { return -1 }
            let levels = tones.map { SpatialProbe.level(interleaved, stride: stride, offset: o, frequency: $0, rate: rate, from: from, count: count) }
            guard let best = levels.indices.max(by: { levels[$0] < levels[$1] }), levels[best] > 0.1 * 0.3 else { return -2 }
            return levels.enumerated().allSatisfy { $0.offset == best || $0.element < levels[best] * 0.1 } ? best : -2
        }
    }
}

@Suite("Multichannel DSD to a multichannel output")
struct MultichannelDSDDeviceTests {
    static let names = ["FL", "FR", "FC", "LFE", "BL", "BR"]

    /// A 5.1 DSD64 file of one tone per channel: DSF, DSDIFF or an SACD image's multichannel area.
    static func write(_ ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcdsd-\(UUID()).\(ext)")
        let tones = SpatialProbe.frequencies(names)
        if ext == "iso" {
            let frames = 98
            let planes = DSDFiles.modulate(rate: SACDFixture.rate, seconds: Double(frames) / 75, tones: tones)
            try SACDFixture.write(to: url, stereo: nil, multichannel: .init(channels: 6, dst: false, planes: planes, tracks: [.init(title: "One", frames: frames)]))
        } else {
            let planes = DSDFiles.modulate(rate: 2_822_400, seconds: 1.3, tones: tones)
            if ext == "dsf" { try DSDFiles.writeDSF(planes, rate: 2_822_400, channelType: 7, to: url) }
            else { try DSDFiles.writeDFF(planes, rate: 2_822_400, channelIDs: ["SLFT", "SRGT", "C   ", "LFE ", "LS  ", "RS  "], to: url) }
        }
        return url
    }

    @Test("5.1 DSF, DSDIFF and SACD ISO: converted to PCM, every channel on its own output of a 16-channel device, the rest silent",
          arguments: ["dsf", "dff", "iso"])
    func fiveOne(ext: String) throws {
        let url = try Self.write(ext)
        defer { try? FileManager.default.removeItem(at: url) }
        let device = MultichannelDeviceTests.device()
        let item = ext == "iso" ? PlayableItem(url: url, sacdArea: .multichannel) : PlayableItem(url: url)
        let session = try #require(try GoldenRender.render([item], device: device).sessions.first)
        #expect(session.plan.dsdConvertedToPCM && session.plan.channels == 6 && session.plan.spatial == .off)
        let rate = session.plan.deviceSampleRate
        let samples = session.words.map { Float(bitPattern: $0) }
        let carried = ToneID.identify(samples, stride: 16, tones: SpatialProbe.frequencies(Self.names), rate: rate,
                                      from: Int(rate * 0.3), count: Int(rate * 0.6))
        #expect(carried == Array(0..<6) + Array(repeating: -1, count: 10), "\(ext) at \(rate) Hz: \(carried)")
    }
}
