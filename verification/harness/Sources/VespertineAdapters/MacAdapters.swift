//
// Vespertine verification: the contracts that need Vespertine's Swift code (macOS only): DoP packing
// (RawDoPDecoder), 24-bit to Float32 decoding (SourceOpener and AVAudioConverter as the engine sets it up),
// rate planning (FormatPlanner) and the BIT-PERFECT verdict (SignalPath).
// SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import AVFAudio
import Contracts
import Foundation
import SFBAudioEngine
@testable import VespertineAudio

// MARK: - DoP packing

/// Raw DSD from memory, in the form RawDoPDecoder reads it (one plane per channel, MSB oldest).
final class MemoryDSD: RawDSDSource {
    let planes: [[UInt8]]
    var position = 0

    init(planes: [[UInt8]]) { self.planes = planes }

    var channelCount: Int { planes.count }
    var dsdRate: Double { 2_822_400 }
    var dsdLength: Int64 { Int64(planes.first?.count ?? 0) }
    var isOpen: Bool { true }
    var inputSource: InputSource { InputSource(data: Data()) }

    func readDSD(into out: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>>, bytes: Int) throws -> Int {
        let n = max(0, min(bytes, Int(dsdLength) - position))
        guard n > 0 else { return 0 }
        for (c, plane) in planes.enumerated() {
            plane.withUnsafeBufferPointer { out[c].update(from: $0.baseAddress! + position, count: n) }
        }
        position += n
        return n
    }

    func seekDSD(to position: Int64) throws { self.position = Int(position) }
    func close() throws {}
}

/// RawDoPDecoder, which packs DSD into DoP frames for playback (FFmpegDecoder.swift:165-250), fed from memory.
/// Its output is the 24-bit DoP sample over 2^23 in Float32 (line 239), read back here as the 24-bit value.
///
/// The input checks below are the adapter's, not Vespertine's: RawDoPDecoder reads from a source that can't
/// express unequal channel lengths, and it drops a trailing odd byte. No requirement record covers them.
struct RawDoPPacker: DoPPacker {
    func dopPack(dsd: [[UInt8]], firstMarker: UInt8) throws -> [[UInt32]] {
        guard !dsd.isEmpty, firstMarker == 0x05 || firstMarker == 0xFA,
              dsd.allSatisfy({ $0.count == dsd[0].count }), dsd[0].count % 2 == 0 else { throw InvalidInput() }
        let decoder = try RawDoPDecoder(source: MemoryDSD(planes: dsd))
        decoder.nextMarker = firstMarker == 0x05 ? 0 : 1
        guard let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096) else { throw InvalidInput() }
        var out = [[UInt32]](repeating: [], count: dsd.count)
        while true {
            try decoder.decode(into: buffer, length: 4096)
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { break }
            for c in 0..<dsd.count {
                for i in 0..<n {
                    let word = UInt32(bitPattern: Int32(clamping: Int64((Double(data[c][i]) * 2_147_483_648).rounded())))
                    out[c].append(word >> 8)
                }
            }
        }
        return out
    }
}

// MARK: - 24-bit integer to Float32

/// What a 24-bit file goes through before the ring: SourceOpener's decoder, then AVAudioConverter set up as
/// PlaybackEngine.swift:183-196 sets it up for an equal-rate PCM plan (the path DecodeAndAnalysisTests checks).
/// The samples are written as a mono 24-bit WAV at 96 kHz.
struct DecoderFloatOutput: FloatOutput {
    func makeStage(channels: Int, capacityFrames: Int) -> any FloatStage {
        RenderContext(channels: channels, capacityFrames: capacityFrames).map(RenderFloatStage.init) ?? RefusedStage(channels: channels)
    }

    /// Empty when the file can't be decoded (checks then fail on the count).
    func int24ToFloat(samples: [Int32]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("verification-int24-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try Self.wav24(samples, rate: 96_000).write(to: url)
            let probed = try SourceOpener.probe(url)
            let device = DeviceCapabilities(
                sampleRates: [96_000],
                physicalFormats: [PhysicalFormat(minRate: 96_000, maxRate: 96_000, bitDepth: 24, isInteger: true, isMixable: true, channels: 1)],
                outputChannels: 1, supportsDoP: false)
            let plan = FormatPlanner.plan(source: probed.format, device: device)
            let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: url))
            guard let outFormat = AudioFormats.float32(sampleRate: plan.deviceSampleRate, channels: plan.channels, interleaved: true),
                  let converter = AVAudioConverter(from: decoder.processingFormat, to: outFormat),
                  let input = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 16_384),
                  let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(samples.count))
            else { return [] }
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converter.sampleRateConverterQuality = .max
            converter.downmix = true
            converter.dither = false
            var done = false
            _ = converter.convert(to: output, error: nil) { n, status in
                if done { status.pointee = .endOfStream; return nil }
                try? decoder.decode(into: input, length: min(n, input.frameCapacity))
                if input.frameLength == 0 { done = true; status.pointee = .endOfStream; return nil }
                status.pointee = .haveData
                return input
            }
            guard let data = output.floatChannelData else { return [] }
            return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
        } catch {
            return []
        }
    }

    /// A mono WAV of signed 24-bit little-endian samples.
    static func wav24(_ samples: [Int32], rate: UInt32) -> Data {
        func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        let dataBytes = UInt32(samples.count * 3)
        var d = [UInt8]()
        d.reserveCapacity(Int(dataBytes) + 44)
        d += Array("RIFF".utf8) + le(36 + dataBytes) + Array("WAVE".utf8)
        d += Array("fmt ".utf8) + le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1)) + le(rate) + le(rate * 3) + le(UInt16(3)) + le(UInt16(24))
        d += Array("data".utf8) + le(dataBytes)
        for s in samples {
            let u = UInt32(bitPattern: s)
            d += [UInt8(u & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u >> 16 & 0xFF)]
        }
        return Data(d)
    }
}

// MARK: - Rate planning

/// FormatPlanner, which the docs describe (FEATURES.md:33, ARCHITECTURE.md:23).
struct PlannerAdapter: RatePlanner {
    func chooseRate(sourceRate: Double, offeredRates: [Double], policy: Policy) -> Double {
        let device = DeviceCapabilities(sampleRates: offeredRates, physicalFormats: [], outputChannels: 2, supportsDoP: false)
        return FormatPlanner.chooseRate(for: sourceRate, device: device, policy: Self.policy(policy))
    }

    func dopCarrierRate(dsdRate: Double) -> Double { FormatPlanner.dopCarrierRate(dsdRate) }

    /// The whole planner, for a stereo DSD file, with the device's integer formats available at every offered rate.
    func planDSD(dsdRate: Double, device: DSDDevice) -> DSDPlan {
        let low = device.offeredRates.min() ?? 0, high = device.offeredRates.max() ?? 0
        let caps = DeviceCapabilities(
            sampleRates: device.offeredRates,
            physicalFormats: device.integerBitDepths.map {
                PhysicalFormat(minRate: low, maxRate: high, bitDepth: $0, isInteger: true, isMixable: true, channels: device.channels)
            },
            outputChannels: device.channels, supportsDoP: device.dopEnabled)
        let source = SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: dsdRate, bitDepth: nil, channels: 2)
        let plan = FormatPlanner.plan(source: source, device: caps, policy: .matchSource)
        return DSDPlan(mode: plan.mode == .dop ? .dop : .pcm, deviceRate: plan.deviceSampleRate,
                       pcmRate: plan.dsdConvertedToPCM ? plan.decodedSampleRate : nil)
    }

    static func policy(_ p: Policy) -> VespertineAudio.RatePolicy {
        switch p {
        case .matchSource: .matchSource
        case .maximum: .maximum
        case .fixed(let rate): .fixed(rate)
        }
    }
}

// MARK: - BIT-PERFECT verdict

/// SignalPath.statusLine (SignalPath.swift), fed the way OutputSession fills in AppliedFormat.
///
/// OutputSession needs a real device, so the readback step is reproduced here from OutputSession.swift, line by
/// line, and nothing else is added (the line numbers are those of 98cad1a):
/// - a failed nominal-rate read is replaced by the requested rate (line 94), but every output stream's virtual
///   format must then carry that rate (lines 99, 109-111). The stream format is a second reading of the device's
///   rate, so when the system reports no rate (`nominalRate` nil) it can't confirm the requested one and the
///   session isn't opened. (A nominal-rate read that fails while the streams still report the rate opens only if
///   they carry the requested rate; the contract's one rate field can't express that case.)
/// - a failed physical-format read is replaced by the planned bit depth, and the format is assumed integer
///   (lines 129-130);
/// - the device is held exclusively when the hog-mode owner read back is this process; a failed read counts as
///   −1, no owner (DeviceControl.hogOwner and acquireHog, lines 318-331);
/// - integer mode is in effect only for PCM with the device held (line 98);
/// - the session isn't opened (so there is no badge) when the device carries fewer channels than planned or the
///   rate read back isn't a usable rate (lines 111-117), or, for DoP and bitstream, when the device isn't held,
///   the physical format is under 24 (DoP) or 16 bits, or the rate read back differs from the plan (lines 118-123).
/// The device class picks a device name and transport, and DeviceProfile.detect classifies it as for a real
/// device. (AirPods Max over Bluetooth would classify as USB-C if an AirPods Max USB audio interface were attached
/// to the Mac running the tests.)
struct SignalPathVerdict: BadgeVerdict {
    static let notOpened = "OUTPUT NOT OPENED"

    func verdict(_ i: VerdictInput) -> String {
        let source = SourceFormat(encoding: Self.encoding(i.source.encoding), codec: i.source.codec, sampleRate: i.source.sampleRate,
                                  bitDepth: i.source.bitDepth, channels: i.source.channels)
        let mode: OutputPlan.Mode = switch i.plan.mode { case .pcm: .pcm; case .dop: .dop; case .bitstream: .bitstream }
        // The plan's decoded rate differs from the device rate exactly when it resamples (OutputPlan.resamples).
        let decoded = !i.plan.resampling ? i.plan.requestedRate
            : abs(i.source.sampleRate - i.plan.requestedRate) >= 0.5 ? i.source.sampleRate : i.plan.requestedRate * 2
        var plan = OutputPlan(mode: mode, deviceSampleRate: i.plan.requestedRate, decodedSampleRate: decoded,
                              physicalBitDepth: i.plan.requestedBitDepth, channels: i.plan.channels,
                              dsdConvertedToPCM: i.plan.dsdConvertedToPCM, reason: "")
        plan.spatial = switch i.plan.spatial { case .off: .off; case .fixed: .fixed; case .headTracked: .headTracked }
        if plan.spatial != .off { plan.deviceChannelCount = 2 }
        plan.integerSamples = i.plan.integerMode

        let hogged = (i.readback.hogOwnerPID ?? -1) == i.readback.ownPID
        let rate = i.readback.nominalRate ?? plan.deviceSampleRate
        let physical: (bits: Int, integer: Bool)? = i.readback.physicalBitDepth.flatMap { bits in
            i.readback.physicalIsInteger.map { (bits, $0) }
        }
        // Lines 99, 109-111: the streams' virtual formats must carry `rate`; with no rate reported they can't.
        guard i.readback.nominalRate != nil else { return Self.notOpened }
        guard i.readback.deviceChannels >= plan.deviceChannels, rate.isFinite, rate > 0, rate <= 3_072_000 else { return Self.notOpened }
        if plan.isPassthrough, !hogged || (physical?.bits ?? 0) < (mode == .dop ? 24 : 16) || abs(rate - plan.deviceSampleRate) >= 0.5 {
            return Self.notOpened
        }
        let applied = AppliedFormat(
            sampleRate: rate,
            physicalBitDepth: physical?.bits ?? plan.physicalBitDepth,
            physicalIsInteger: physical?.integer ?? true,
            virtualChannels: i.readback.deviceChannels,
            exclusive: hogged,
            bufferFrames: 512,
            integerMode: plan.integerSamples && hogged && mode == .pcm)

        let device = Self.device(i.deviceClass)
        let volume: SignalPath.VolumeStage = switch i.processing.volume {
            case .hardware: .hardware
            case .fixed: .fixed
            case .digital(let dB): .digital(dB: dB)
        }
        let path = SignalPath(source: source, decoderName: "", plan: plan, applied: applied, deviceName: device.name,
                              deviceUID: "", deviceProfile: DeviceProfile.detect(device), volume: volume,
                              replayGainDB: i.processing.replayGainDB,
                              equalizer: i.processing.equalizerActive ? "Preset" : nil,
                              otherAppsPlaying: i.processing.otherAppsPlaying,
                              concealedFrames: i.processing.concealedFrames)
        return path.statusLine
    }

    static func encoding(_ e: VerdictInput.Encoding) -> SourceFormat.Encoding {
        switch e { case .pcm: .pcm; case .lossy: .lossy; case .dsd: .dsd }
    }

    static func device(_ c: VerdictInput.DeviceClass) -> OutputDevice {
        let (name, transport): (String, Transport) = switch c {
            case .usbDAC: ("USB Audio DAC", .usb)
            case .builtInHeadphones: ("External Headphones", .builtIn)
            case .builtInSpeakers: ("MacBook Pro Speakers", .builtIn)
            case .bluetooth: ("Bluetooth Speaker", .bluetooth)
            case .airPlay: ("Living Room", .airPlay)
            case .virtual: ("Virtual Device", .virtual)
            case .aggregate: ("Aggregate Device", .aggregate)
            case .airPodsMaxUSBC: ("AirPods Max", .usb)
            case .airPodsMaxBluetooth: ("AirPods Max", .bluetooth)
            case .other: ("HDMI", .hdmi)
        }
        return OutputDevice(id: 0, uid: "", name: name, manufacturer: "", modelUID: nil, transport: transport, nominalSampleRate: 48_000,
                            capabilities: DeviceCapabilities(sampleRates: [48_000], physicalFormats: [], outputChannels: 2, supportsDoP: false),
                            hasHardwareVolume: false, isDefault: false)
    }
}

// MARK: - IEC 61937 carriers (for the FFmpeg and carrier-scan oracles, hardware/IEC61937-ORACLE.md)

extension Vespertine {
    /// Writes the carrier Vespertine sends to a receiver for a Dolby Digital or Dolby Digital Plus file: the
    /// output of BitstreamDecoder, the same object the engine plays in bitstream mode, as a 16-bit stereo WAV at
    /// the carrier rate. Nothing here builds a burst; the samples are BitstreamDecoder's, written unchanged.
    public static func writeCarrier(from source: URL, to destination: URL) throws {
        let decoder = try BitstreamDecoder.open(url: source)
        let format = decoder.processingFormat
        let out = try AVAudioFile(forWriting: destination,
                                  settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                                             AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                                             AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false],
                                  commonFormat: .pcmFormatInt16, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { return }
        while true {
            try decoder.decode(into: buffer, length: 8192)
            if buffer.frameLength == 0 { break }
            try out.write(from: buffer)
        }
    }
}
// MARK: - SACD images (for the sacd_extract comparison, hardware/SACD-ORACLE.md)

extension Vespertine {
    /// For every area of an SACD image: the table of contents as Vespertine reads it (`toc.json`), each track's
    /// DSD as Vespertine plays it (`<area>-<NN>.dff`), and the whole area in one piece (`<area>-all.dff`). The DSD
    /// comes from SACDSource, the object the engine plays (DST frames decoded by vespertine_dst.c), written as
    /// DSDIFF 1.5 (§3.3: channel bytes interleaved in channel order, most significant bit oldest). Returns the
    /// frames concealed as silence, which must be 0 for an undamaged image.
    @discardableResult
    public static func writeSACDAreas(image url: URL, to dir: URL) throws -> Int {
        let image = try SACDImage.read(url)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var toc: [[String: Any]] = []
        var concealed = 0
        for area in image.areas {
            toc.append([
                "area": area.kind.rawValue, "channels": area.channels, "sampleRate": area.sampleRate, "dst": area.isDST,
                "firstSector": area.firstSector, "lastSector": area.lastSector,
                "tracks": area.tracks.map { ["number": $0.number, "startFrame": $0.startFrame, "frameCount": $0.frameCount,
                                             "title": $0.title ?? "", "performer": $0.performer ?? ""] as [String: Any] },
            ])
            for track in area.tracks {
                let frames = track.startFrame..<(track.startFrame + track.frameCount)
                concealed += try writeDFF(SACDSource(url: url, area: area, frames: frames), area: area,
                                          to: dir.appendingPathComponent(String(format: "%@-%02d.dff", area.kind.rawValue, track.number)))
            }
            concealed += try writeDFF(SACDSource(url: url, area: area, frames: area.frameRange), area: area,
                                      to: dir.appendingPathComponent("\(area.kind.rawValue)-all.dff"))
        }
        let json = try JSONSerialization.data(withJSONObject: ["image": url.lastPathComponent, "areas": toc],
                                              options: [.prettyPrinted, .sortedKeys])
        try json.write(to: dir.appendingPathComponent("toc.json"))
        return concealed
    }

    private static func writeDFF(_ source: SACDSource, area: SACDImage.Area, to url: URL) throws -> Int {
        func be64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (56 - 8 * $0)) } }
        func be32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - 8 * $0)) } }
        func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
            Array(id.utf8) + be64(UInt64(body.count)) + body + (body.count % 2 == 1 ? [0] : [])
        }
        let ids: [String] = switch area.channels {
        case 2: ["SLFT", "SRGT"]
        case 5: ["MLFT", "MRGT", "C   ", "LS  ", "RS  "]
        case 6: ["MLFT", "MRGT", "C   ", "LFE ", "LS  ", "RS  "]
        default: (1...area.channels).map { String(format: "C%03d", $0) }
        }
        let name = Array("not compressed".utf8)
        let prop = Array("SND ".utf8) + chunk("FS  ", be32(UInt32(area.sampleRate)))
            + chunk("CHNL", [UInt8(area.channels >> 8), UInt8(area.channels & 0xFF)] + ids.flatMap { Array($0.utf8) })
            + chunk("CMPR", Array("DSD ".utf8) + [UInt8(name.count)] + name)
        let soundBytes = UInt64(source.dsdLength) * UInt64(area.channels)
        let head = Array("DSD ".utf8) + chunk("FVER", be32(0x0105_0000)) + chunk("PROP", prop)
        let total = UInt64(head.count) + 12 + soundBytes + soundBytes % 2
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        try out.write(contentsOf: Array("FRM8".utf8) + be64(total) + head + Array("DSD ".utf8) + be64(soundBytes))
        var buffer = [UInt8](repeating: 0, count: area.frameBytes * area.channels)
        while true {
            let n = try buffer.withUnsafeMutableBufferPointer { try source.readInterleaved(into: $0.baseAddress!, bytes: area.frameBytes) }
            if n == 0 { break }
            try out.write(contentsOf: buffer[0..<(n * area.channels)])
        }
        if soundBytes % 2 == 1 { try out.write(contentsOf: [0]) }
        return source.concealedFrames
    }
}
#endif
