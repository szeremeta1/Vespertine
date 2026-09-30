//
// Vespertine — Spatial Audio end to end, for every channel layout in every format: files are made with FFmpeg
// (one tone per channel), then go through the app's own probe, decoder, converter and Apple's spatial mixer.
// Each channel must reach the bed slot of its own speaker position, and be heard on the correct side.
// Needs FFmpeg; runs when VESPERTINE_SPATIAL_MATRIX is set (it takes a minute or two).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import Testing
@testable import VespertineAudio

enum FFmpegTool {
    static let path = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    static var probePath: String? { path.map { ($0 as NSString).deletingLastPathComponent + "/ffprobe" } }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// FFmpeg's standard layouts, each with its channels in FFmpeg's (native) order.
    static var layouts: [(name: String, channels: [String])] {
        guard let path else { return [] }
        let text = run(path, ["-hide_banner", "-layouts"]).output
        guard let start = text.range(of: "Standard channel layouts:") else { return [] }
        return text[start.upperBound...].split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), parts[1].split(separator: "+").map(String.init))
        }
    }
}

/// One tone per channel: which channel ended up where, and how it is heard.
struct SpatialProbe {
    static let rate = 48_000.0
    static let seconds = 1.5

    /// Tone of each channel: low for LFE (lossy codecs keep only its bottom 120 Hz), spread out elsewhere.
    static func frequencies(_ channels: [String]) -> [Double] {
        var next = 0
        return channels.map { name in
            if name == "LFE" { return 55 }
            if name == "LFE2" { return 85 }
            defer { next += 1 }
            return 420 + Double(next) * 170
        }
    }

    /// Speaker position(s) a channel of FFmpeg's may carry in Core Audio's names (`shortName` of its label).
    static func expected(_ name: String, in all: [String]) -> Set<String> {
        let hasSides = all.contains("SL") || all.contains("SR")
        switch name {
        case "FL": return ["L"]
        case "FR": return ["R"]
        case "FC": return ["C"]
        case "LFE", "LFE2": return ["LFE"]
        // Core Audio has two conventions for 7.1: back = Rls, side = Ls (FLAC, MPEG) or back = Ls, side = Lsd
        // (WAVE speaker masks). Either way the back pair stays behind the side pair, each in its own slot.
        case "BL": return hasSides ? ["Lrs", "Ls"] : ["Ls", "Lrs"]
        case "BR": return hasSides ? ["Rrs", "Rs"] : ["Rs", "Rrs"]
        case "SL": return ["Ls", "Lsd"]
        case "SR": return ["Rs", "Rsd"]
        case "BC": return ["Cs"]
        case "FLC": return ["Lc"]
        case "FRC": return ["Rc"]
        case "WL": return ["Lw"]
        case "WR": return ["Rw"]
        case "SDL": return ["Lsd"]
        case "SDR": return ["Rsd"]
        case "TC": return ["Top"]
        case "TFL": return ["Ltf"]
        case "TFC": return ["Ctf"]
        case "TFR": return ["Rtf"]
        case "TBL": return ["Ltr"]
        case "TBC": return ["Ctr"]
        case "TBR": return ["Rtr"]
        case "TSL": return ["Lts"]
        case "TSR": return ["Rts"]
        case "BFC": return ["Cb"]
        case "BFL": return ["Lb"]
        case "BFR": return ["Rb"]
        default: return []
        }
    }

    enum Side { case left, right, middle }
    static func side(_ position: String) -> Side {
        if position.hasPrefix("LFE") { return .middle }
        if position.hasPrefix("L") { return .left }
        if position.hasPrefix("R") { return .right }
        return .middle
    }

    /// Whether FFmpeg decodes `url` back to one tone per channel in the order written: files its own
    /// encoder got wrong (libopus 5.0 and 6.1, for one) prove nothing about Vespertine.
    static func roundTrips(_ url: URL, channels: [String], ffmpeg: String) -> Bool {
        let raw = url.appendingPathExtension("check.f32")
        defer { try? FileManager.default.removeItem(at: raw) }
        guard FFmpegTool.run(ffmpeg, ["-v", "error", "-y", "-i", url.path, "-f", "f32le", "-ar", "48000", raw.path]).status == 0,
              let data = try? Data(contentsOf: raw) else { return false }
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let n = channels.count, tones = frequencies(channels)
        guard samples.count / n > Int(rate) else { return false }
        return (0..<n).allSatisfy { c in
            let levels = tones.map { level(samples, stride: n, offset: c, frequency: $0, rate: rate, from: Int(rate * 0.4), count: Int(rate * 0.5)) }
            return levels.indices.max { levels[$0] < levels[$1] } == c && levels.enumerated().allSatisfy { $0.offset == c || $0.element < levels[c] * 0.1 }
        }
    }

    /// Interleaved float, `channels` in FFmpeg's order, one tone each at -20 dBFS.
    static func signal(_ channels: [String]) -> Data {
        let n = channels.count, frames = Int(rate * seconds)
        let f = frequencies(channels)
        var samples = [Float](repeating: 0, count: frames * n)
        for i in 0..<frames {
            let t = Double(i) / rate
            for c in 0..<n { samples[i * n + c] = Float(0.1 * sin(2 * .pi * f[c] * t)) }
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Amplitude of `frequency` in `samples[offset + k * stride]` (Goertzel over the measuring window).
    static func level(_ samples: [Float], stride: Int, offset: Int, frequency: Double, rate: Double, from: Int, count: Int) -> Double {
        let w = 2 * Double.pi * frequency / rate, coeff = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for k in from..<(from + count) {
            let s = Double(samples[k * stride + offset]) + coeff * s1 - s2
            s2 = s1; s1 = s
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return 2 * sqrt(max(power, 0)) / Double(count)
    }

    struct Result {
        var decodedLabels: [String] = []
        var bed: [String] = []
        var problems: [String] = []
        var ild: [String: Double] = [:]
        /// Channels the bed has no speaker for, placed on the nearest ones.
        var nearby: [String] = []
    }

    /// Decodes `url` the way the engine does for a Spatial Audio plan, and checks every channel.
    static func check(_ url: URL, channels: [String]) throws -> Result {
        var result = Result()
        let probed = try SourceOpener.probe(url)
        let f = probed.format
        let pcmRate = f.encoding == .dsd ? FormatPlanner.dsdToPCMRate(f.sampleRate) : f.sampleRate
        var plan = FormatPlanner.plan(source: f, device: DeviceCapabilities(sampleRates: [pcmRate], physicalFormats: [], outputChannels: 2,
                                                                            supportsDoP: false), spatial: .fixed)
        plan.integerSamples = false
        guard plan.spatial == .fixed else { result.problems.append("not planned for Spatial Audio (\(f.channels) ch)"); return result }
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: url))
        result.decodedLabels = decoder.processingFormat.channelLayout?.shortNames ?? ["(no layout)"]
        guard let bed = OutputSession.routeLayout(plan: plan, speakers: nil) else { result.problems.append("no bed"); return result }
        result.bed = bed.shortNames
        let n = Int(bed.channelCount)
        // As the engine does: converted in the file's own channel order, then placed on the bed.
        let own = decoder.processingFormat.channelLayout
        let router = plan.spatialBed == nil ? nil
            : (ChannelLayouts.speakerLabels(own) ?? ChannelLayouts.standardLabels(channels: Int(decoder.processingFormat.channelCount)))
                .flatMap { BedRouter(source: $0, bed: bed.channelLabels) }
        if let router, router.dropped > 0 { result.problems.append("\(router.dropped) channel(s) have no place on the bed") }
        let outFormat = try #require(router.map { AudioFormats.float32(sampleRate: plan.deviceSampleRate, channels: $0.sourceChannels, interleaved: true, layout: own) }
                                     ?? AudioFormats.float32(sampleRate: plan.deviceSampleRate, channels: n, interleaved: true, layout: bed))
        let width = Int(outFormat.channelCount)
        let converter = try #require(AVAudioConverter(from: decoder.processingFormat, to: outFormat))
        converter.downmix = true
        converter.dither = false
        let rate = plan.deviceSampleRate
        let total = Int(rate * seconds) - Int(rate * 0.05)
        let input = try #require(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 8192))
        let output = try #require(AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 8192))
        var interleaved: [Float] = []
        interleaved.reserveCapacity(total * n)
        var ended = false
        while interleaved.count < total * n {
            let status = converter.convert(to: output, error: nil) { _, s in
                if ended { s.pointee = .endOfStream; return nil }
                do { try decoder.decode(into: input, length: input.frameCapacity) } catch { ended = true }
                if input.frameLength == 0 { ended = true; s.pointee = .endOfStream; return nil }
                s.pointee = .haveData
                return input
            }
            if output.frameLength == 0 || status == .error { break }
            let frames = Int(output.frameLength)
            if let router {
                var placed = [Float](repeating: 0, count: frames * n)
                router.route(output.floatChannelData![0], into: &placed, frames: frames)
                interleaved += placed
            } else {
                interleaved += UnsafeBufferPointer(start: output.floatChannelData![0], count: frames * width)
            }
        }
        let frames = interleaved.count / n
        guard frames > Int(rate) else { result.problems.append("decoded only \(frames) frames"); return result }
        let from = Int(rate * 0.4), count = Int(rate * 0.8)
        let tones = frequencies(channels)

        // 1. Each channel reaches exactly the bed slot of its own position (its own slot), at its own level.
        var used: Set<Int> = []
        for (c, name) in channels.enumerated() {
            let want = expected(name, in: channels)
            let levels = (0..<n).map { level(interleaved, stride: n, offset: $0, frequency: tones[c], rate: rate, from: from, count: count) }
            let heard = (0..<n).filter { levels[$0] > 0.1 * 0.1 }        // within 20 dB of the source
            let total = levels.map { $0 * $0 }.reduce(0, +).squareRoot()
            // When the bed has no such speaker, the nearest ones are right (checked by side below).
            let bedHasIt = result.bed.contains { want.contains($0) }
            if total < 0.1 * 0.25 {
                result.problems.append("\(name) lost (\(String(format: "%.0f", 20 * log10(max(total, 1e-9) / 0.1))) dB)")
            } else if !bedHasIt {
                result.nearby.append(name)
            } else if heard.count != 1 || !want.contains(result.bed[heard[0]]) {
                result.problems.append("\(name) → \(heard.map { result.bed[$0] }.joined(separator: "+")) (want \(want.sorted().joined(separator: "/")))")
            } else if !used.insert(heard[0]).inserted {
                result.problems.append("\(name) shares \(result.bed[heard[0]]) with another channel")
            }
        }

        // 2. Apple's spatial mixer places each one on the correct side.
        let renderer = try SpatialRenderer(inputLayout: bed, channels: n, sampleRate: rate, maxFrames: 4096, mode: .fixed)
        let binaural = renderer.render(interleaved: interleaved, frames: frames)
        for (c, name) in channels.enumerated() {
            guard let position = expected(name, in: channels).sorted().first else { continue }
            let l = level(binaural, stride: 2, offset: 0, frequency: tones[c], rate: rate, from: from, count: count)
            let r = level(binaural, stride: 2, offset: 1, frequency: tones[c], rate: rate, from: from, count: count)
            let ild = 20 * log10(max(l, 1e-9) / max(r, 1e-9))
            result.ild[name] = ild
            if max(l, r) < 0.1 * 0.03 {
                result.problems.append("\(name) silent after Spatial Audio (\(String(format: "%.0f", 20 * log10(max(l, r, 1e-9) / 0.1))) dB)")
                continue
            }
            switch side(position) {
            case .left where ild < 2: result.problems.append("\(name) not on the left (ILD \(String(format: "%+.1f", ild)) dB)")
            case .right where ild > -2: result.problems.append("\(name) not on the right (ILD \(String(format: "%+.1f", ild)) dB)")
            case .middle where abs(ild) > 2.5: result.problems.append("\(name) off-centre (ILD \(String(format: "%+.1f", ild)) dB)")
            default: break
            }
        }
        return result
    }
}

/// FFmpeg names a custom layout by a standard one with the same channels ("FL+FR+LFE+SL+SR" reads back as "4.1(side)"?)
/// or as "N channels (FL+FR+…)".
enum ChannelLayoutName {
    static func same(_ stored: String, _ channels: [String]) -> Bool {
        FFmpegTool.layouts.first { $0.name == stored }?.channels == channels
    }
}

@Suite("Spatial Audio for every layout and format")
struct SpatialMatrixTests {
    /// Codec name, file extension, FFmpeg arguments.
    static let codecs: [(name: String, ext: String, args: [String])] = [
        ("FLAC", "flac", ["-c:a", "flac"]),
        ("WAV", "wav", ["-c:a", "pcm_s24le"]),
        ("AIFF", "aiff", ["-c:a", "pcm_s24be"]),
        ("CAF", "caf", ["-c:a", "pcm_s24le"]),
        ("WavPack", "wv", ["-c:a", "wavpack"]),
        ("ALAC", "m4a", ["-c:a", "alac"]),
        ("TTA", "tta", ["-c:a", "tta"]),
        ("MLP", "mlp", ["-c:a", "mlp", "-strict", "-2"]),
        ("TrueHD", "thd", ["-c:a", "truehd", "-strict", "-2"]),
        ("DTS", "dts", ["-c:a", "dca", "-strict", "-2", "-b:a", "1509k"]),
        ("AC-3", "ac3", ["-c:a", "ac3", "-b:a", "640k"]),
        ("E-AC-3", "ec3", ["-c:a", "eac3", "-b:a", "1024k", "-f", "eac3"]),
        ("AAC", "mp4", ["-c:a", "aac", "-b:a", "768k"]),
        ("Opus", "opus", ["-c:a", "libopus", "-b:a", "512k"]),
    ]

    /// Failures that belong to macOS's own decoders, not to Vespertine (codec, layouts).
    static let knownLimits: [(codec: String, layouts: Set<String>, why: String)] = [
        ("AAC", ["2.1", "3.0(back)", "3.1", "4.1", "7.0", "octagonal"], "macOS's AAC decoder can't open layouts described by a program config element"),
        ("AAC", ["7.1(wide)"], "macOS's AAC decoder mislabels channel configuration 7"),
        ("AIFF", ["6.0", "6.0(front)", "3.1.2", "hexagonal", "6.1", "6.1(back)", "6.1(front)", "7.0", "7.0(front)", "7.1(wide)", "5.1.2",
                  "5.1.2(back)", "octagonal", "cube", "5.1.4", "7.1.2", "7.1.4", "9.1.4"],
         "macOS ignores an AIFF's speaker bitmap: the channels are taken in the standard order (or aren't placed above 8)"),
        ("WavPack", ["9.1.6", "22.2"], "SFBAudioEngine reads no WavPack speaker mask above 8 channels"),
        ("TTA", ["6.1", "6.1(back)", "6.1(front)", "7.0", "7.0(front)", "7.1", "7.1(wide)", "7.1(wide-side)", "5.1.2", "5.1.2(back)", "octagonal", "cube",
                 "5.1.4", "7.1.2", "7.1.4", "7.2.3", "9.1.4", "9.1.6", "hexadecagonal", "22.2"], "libtta decodes at most 6 channels (it refuses the file)"),
    ]

    @Test(.enabled(if: FFmpegTool.path != nil && ProcessInfo.processInfo.environment["VESPERTINE_SPATIAL_MATRIX"] != nil))
    func everyLayoutEveryFormat() throws {
        let ffmpeg = FFmpegTool.path!, ffprobe = FFmpegTool.probePath!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-spatial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let only = ProcessInfo.processInfo.environment["VESPERTINE_SPATIAL_MATRIX"].flatMap { $0 == "1" ? nil : Set($0.split(separator: ",").map(String.init)) }
        // FFmpeg's named layouts, plus the Dolby Digital channel modes that have no name there (2/1 and 2/2 with LFE).
        let layouts = FFmpegTool.layouts.filter { $0.channels.count > 2 && !$0.name.hasPrefix("binaural") && !$0.name.hasPrefix("downmix") }
            + [("FL+FR+LFE+BC", ["FL", "FR", "LFE", "BC"]), ("FL+FR+LFE+SL+SR", ["FL", "FR", "LFE", "SL", "SR"])]
        var failures: [String] = [], skipped: [String: [String]] = [:], passed = 0
        var limits: [String: [String]] = [:], nearby: [String] = []
        for layout in layouts {
            let raw = dir.appendingPathComponent("\(layout.name).f32")
            try SpatialProbe.signal(layout.channels).write(to: raw)
            for codec in Self.codecs where only == nil || only!.contains(codec.name) {
                let url = dir.appendingPathComponent("\(layout.name)-\(codec.name).\(codec.ext)")
                let made = FFmpegTool.run(ffmpeg, ["-v", "error", "-y", "-f", "f32le", "-ar", "48000", "-ch_layout", layout.name, "-i", raw.path]
                                          + codec.args + [url.path])
                guard made.status == 0 else { skipped[codec.name, default: []].append(layout.name); continue }
                // Only files that say what they hold: FFmpeg must read back the layout it was given.
                let stored = FFmpegTool.run(ffprobe, ["-v", "error", "-show_entries", "stream=channel_layout", "-of", "default=nw=1:nk=1", url.path])
                    .output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard stored == layout.name || stored.hasSuffix("(\(layout.name))") || ChannelLayoutName.same(stored, layout.channels) else {
                    skipped[codec.name, default: []].append("\(layout.name)→\(stored.isEmpty ? "?" : stored)")
                    continue
                }
                guard SpatialProbe.roundTrips(url, channels: layout.channels, ffmpeg: ffmpeg) else {
                    skipped[codec.name, default: []].append("\(layout.name) (FFmpeg can't decode its own file)")
                    continue
                }
                let known = Self.knownLimits.first { $0.codec == codec.name && $0.layouts.contains(layout.name) }
                do {
                    let r = try SpatialProbe.check(url, channels: layout.channels)
                    if !r.nearby.isEmpty { nearby.append("\(codec.name) \(layout.name): \(r.nearby.joined(separator: " "))") }
                    if r.problems.isEmpty { passed += 1 } else if let known {
                        limits[known.why, default: []].append("\(codec.name) \(layout.name)")
                    } else {
                        failures.append("\(codec.name) \(layout.name): decoder \(r.decodedLabels.joined(separator: " ")) · bed \(r.bed.joined(separator: " ")) · "
                                        + r.problems.joined(separator: "; "))
                    }
                } catch {
                    if let known { limits[known.why, default: []].append("\(codec.name) \(layout.name)") }
                    else { failures.append("\(codec.name) \(layout.name): \(error)") }
                }
            }
        }
        print("Spatial matrix: \(passed) passed, \(failures.count) failed, \(limits.values.map(\.count).reduce(0, +)) known limits of macOS decoders")
        for f in failures { print("  ✗ \(f)") }
        for (why, list) in limits.sorted(by: { $0.key < $1.key }) { print("  ~ \(why): \(list.joined(separator: ", "))") }
        for n in nearby { print("  ≈ no such speaker on any bed, placed nearby: \(n)") }
        for (codec, list) in skipped.sorted(by: { $0.key < $1.key }) { print("  – \(codec) can't write: \(list.joined(separator: ", "))") }
        #expect(failures.isEmpty)
    }
}
