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
                let w = UInt32(bitPattern: word(channel: c, frame: f))
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
        // A labelled 7.1 folded into 5.1 stays with Apple's downmix (SpeakerMappingTests.fold), which lowers the whole mix.
    ]

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
