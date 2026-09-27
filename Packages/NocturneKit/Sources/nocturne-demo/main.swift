//
// nocturne-demo — builds a library of original synthesized music in many formats,
// with generative cover art, for development, testing and screenshots.
// Every artist, album and track here is fictional.
//
// Usage: swift run -c release nocturne-demo <output-folder>
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import AVFAudio
import CoreGraphics
import Foundation
import SFBAudioEngine

struct DemoAlbum {
    enum Container { case flac, wav, aiff, alac, wavpack, mp3, dsf, cueFLAC }
    var title: String
    var artist: String
    var year: Int
    var genre: String
    var container: Container
    var rate: Double
    var bits: Int
    var tracks: [String]
    var art: (CGContext, CGFloat) -> Void
    var root: Double              // tonal centre (Hz)
    var seconds: Double = 24
    var bandLimitHz: Double? = nil // simulate an upsampled master
    var padTo16Track: Int? = nil   // simulate a 16-bit track in a 24-bit album
}

// MARK: - Synthesis

/// Slow, consonant chord progressions with soft envelopes: pleasant to test with, compresses well.
func synthesize(rate: Double, seconds: Double, root: Double, seed: Int, bandLimit: Double?) -> [[Double]] {
    let n = Int(rate * seconds)
    var left = [Double](repeating: 0, count: n)
    var right = [Double](repeating: 0, count: n)
    let progressions: [[[Double]]] = [
        [[1, 5.0 / 4, 3.0 / 2, 15.0 / 8], [4.0 / 3, 5.0 / 3, 2, 5.0 / 2], [9.0 / 8, 4.0 / 3, 5.0 / 3, 2], [3.0 / 2, 15.0 / 8, 9.0 / 4, 5.0 / 2]],
        [[1, 6.0 / 5, 3.0 / 2, 9.0 / 5], [4.0 / 5, 1, 6.0 / 5, 3.0 / 2], [2.0 / 3, 1, 5.0 / 4, 3.0 / 2], [3.0 / 4, 9.0 / 10, 9.0 / 8, 3.0 / 2]],
        [[1, 3.0 / 2, 9.0 / 4, 5.0 / 2], [5.0 / 6, 5.0 / 4, 3.0 / 2, 15.0 / 8], [2.0 / 3, 1, 4.0 / 3, 2], [3.0 / 4, 9.0 / 8, 3.0 / 2, 15.0 / 8]],
    ]
    let chords = progressions[seed % progressions.count]
    let chordLen = seconds / Double(chords.count)
    let maxPartialHz = bandLimit ?? rate * 0.45
    for (ci, chord) in chords.enumerated() {
        let start = Int(Double(ci) * chordLen * rate)
        let end = min(n, Int(Double(ci + 1) * chordLen * rate + 1.5 * rate))
        for (vi, ratio) in chord.enumerated() {
            let f = root * ratio * (seed % 2 == 0 ? 1 : 1.0005)
            let pan = 0.5 + 0.35 * sin(Double(vi * 3 + seed))
            for h in 1...8 {
                let fh = f * Double(h)
                guard fh < maxPartialHz else { break }
                let amp = 0.08 / pow(Double(h), 1.3)
                let w = 2 * Double.pi * fh / rate
                for i in start..<end {
                    let t = Double(i - start) / rate
                    let env = min(1, t / 0.8) * exp(-t / (chordLen * 1.4))
                    let s = amp * env * sin(w * Double(i) + Double(vi))
                    left[i] += s * (1 - pan)
                    right[i] += s * pan
                }
            }
        }
    }
    // A gentle arpeggio above the chords.
    let notes = [1.0, 5.0 / 4, 3.0 / 2, 2, 5.0 / 2, 3]
    let step = 0.25 + Double(seed % 3) * 0.125
    var i0 = 0
    var k = 0
    while i0 < n {
        let f = root * 2 * notes[(k * (seed + 2)) % notes.count]
        let len = Int(step * rate * 3)
        for h in 1...4 where f * Double(h) < maxPartialHz {
            let w = 2 * Double.pi * f * Double(h) / rate
            for j in 0..<min(len, n - i0) {
                let t = Double(j) / rate
                let s = 0.05 / Double(h * h) * exp(-t * 3) * sin(w * Double(j))
                left[i0 + j] += s * 0.6
                right[i0 + j] += s * 0.4
            }
        }
        i0 += Int(step * rate)
        k += 1
    }
    // Fade in/out.
    let fade = Int(rate * 1.5)
    for i in 0..<min(fade, n) {
        let g = Double(i) / Double(fade)
        left[i] *= g; right[i] *= g
        left[n - 1 - i] *= g; right[n - 1 - i] *= g
    }
    return [left, right]
}

func quantize(_ channels: [[Double]], bits: Int, padTo16: Bool) -> [[Float]] {
    let effective = padTo16 ? 16 : bits
    let q = Double(1 << (effective - 1))
    var rng = SystemRandomNumberGenerator()
    return channels.map { ch in
        ch.map { s in
            let dither = (Double.random(in: -0.5...0.5, using: &rng) + Double.random(in: -0.5...0.5, using: &rng)) / q
            return Float(max(-1, min(1 - 1 / q, ((s + dither) * q).rounded() / q)))
        }
    }
}

func writePCM(_ samples: [[Float]], rate: Double, bits: Int, to url: URL, format: AudioFormatID = kAudioFormatLinearPCM, bigEndian: Bool = false) throws {
    var settings: [String: Any] = [AVFormatIDKey: format, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2]
    if format == kAudioFormatLinearPCM {
        settings[AVLinearPCMBitDepthKey] = bits
        settings[AVLinearPCMIsFloatKey] = false
        settings[AVLinearPCMIsBigEndianKey] = bigEndian
    } else if format == kAudioFormatAppleLossless {
        settings[AVEncoderBitDepthHintKey] = bits
    }
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let n = samples[0].count
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n))!
    buffer.frameLength = AVAudioFrameCount(n)
    for c in 0..<2 { samples[c].withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: n) } }
    try file.write(from: buffer)
}

/// Minimal DSF writer with a second-order sigma-delta modulator (DSD64).
func writeDSF(_ channels: [[Double]], pcmRate: Double, to url: URL) throws {
    let dsdRate = 2_822_400.0
    let ratio = Int(dsdRate / pcmRate)
    let samplesPerChannel = channels[0].count * ratio
    let blockSize = 4096
    let bytesPerChannel = (samplesPerChannel + 7) / 8
    let blocks = (bytesPerChannel + blockSize - 1) / blockSize
    var channelBytes = [[UInt8]](repeating: [UInt8](repeating: 0, count: blocks * blockSize), count: 2)
    for c in 0..<2 {
        var v1 = 0.0, v2 = 0.0, y = 0.0
        for (i, x0) in channels[c].enumerated() {
            let x1 = i + 1 < channels[c].count ? channels[c][i + 1] : x0
            for r in 0..<ratio {
                let x = (x0 + (x1 - x0) * Double(r) / Double(ratio)) * 0.5 // linear interpolation, -6 dB
                v1 += x - y
                v2 += v1 - y
                y = v2 >= 0 ? 1 : -1
                if y > 0 {
                    let idx = i * ratio + r
                    channelBytes[c][idx >> 3] |= UInt8(1 << (idx & 7)) // LSB first
                }
            }
        }
    }
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let dataBytes = UInt64(blocks * blockSize * 2)
    data.append(contentsOf: Array("DSD ".utf8)); u64(28); u64(28 + 52 + 12 + dataBytes); u64(0)
    data.append(contentsOf: Array("fmt ".utf8)); u64(52); u32(1); u32(0); u32(2); u32(2); u32(UInt32(dsdRate)); u32(1)
    u64(UInt64(samplesPerChannel)); u32(UInt32(blockSize)); u32(0)
    data.append(contentsOf: Array("data".utf8)); u64(12 + dataBytes)
    for b in 0..<blocks {
        for c in 0..<2 { data.append(contentsOf: channelBytes[c][b * blockSize..<(b + 1) * blockSize]) }
    }
    try data.write(to: url)
}

// MARK: - Artwork

func render(_ draw: (CGContext, CGFloat) -> Void) -> Data {
    let size: CGFloat = 1200
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx, size)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
}

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func linear(_ ctx: CGContext, _ s: CGFloat, _ colors: [UInt32], angle: CGFloat = 90) {
    let g = CGGradient(colorsSpace: nil, colors: colors.map { rgb($0) } as CFArray, locations: nil)!
    let r = angle * .pi / 180
    let c = CGPoint(x: s / 2, y: s / 2)
    let d = CGPoint(x: cos(r) * s / 2, y: sin(r) * s / 2)
    ctx.drawLinearGradient(g, start: CGPoint(x: c.x - d.x, y: c.y - d.y), end: CGPoint(x: c.x + d.x, y: c.y + d.y), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ ctx: CGContext, _ center: CGPoint, _ radius: CGFloat, _ colors: [UInt32], fill: Bool = true) {
    let g = CGGradient(colorsSpace: nil, colors: colors.map { rgb($0) } as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: fill ? [.drawsAfterEndLocation] : [])
}

func text(_ ctx: CGContext, _ string: String, size: CGFloat, at point: CGPoint, color: UInt32, serif: Bool = true, italic: Bool = false) {
    var font = NSFont.systemFont(ofSize: size, weight: .regular)
    if serif, let d = font.fontDescriptor.withDesign(.serif) { font = NSFont(descriptor: d, size: size) ?? font }
    if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
    let attr = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor(cgColor: rgb(color))!])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    attr.draw(at: point)
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - Catalogue

let albums: [DemoAlbum] = [
    DemoAlbum(title: "Nocturnes in Graphite", artist: "Elena Voss", year: 2023, genre: "Modern Classical", container: .flac, rate: 192_000, bits: 24,
              tracks: ["Prelude in Ash", "Étude for a Sleeping City", "Graphite", "Lanterns", "The Long Hour"],
              art: { c, s in
                  radial(c, CGPoint(x: s * 0.25, y: s * 0.8), s * 1.1, [0x3B4C63, 0x16202E, 0x07090D])
                  radial(c, CGPoint(x: s * 0.46, y: s * 0.56), s * 0.29, [0xE7D2A6, 0xB08F55, 0x7A5E33], fill: false)
              }, root: 110),
    DemoAlbum(title: "Horizon Line", artist: "The Amber Quartet", year: 2021, genre: "Chamber Jazz", container: .flac, rate: 96_000, bits: 24,
              tracks: ["First Light", "Salt Air", "Long Exposure", "Undertow", "Horizon Line", "Marine Layer", "Last Ferry"],
              art: { c, s in
                  linear(c, s, [0x2A1414, 0x6B2A22, 0xD0784D], angle: 290)
                  c.setFillColor(rgb(0xFFE6C8, 0.6)); c.fill(CGRect(x: 0, y: s * 0.42, width: s, height: 3))
              }, root: 130.8, padTo16Track: 4),
    DemoAlbum(title: "Sessions III", artist: "Marlowe Trio", year: 2019, genre: "Jazz", container: .wav, rate: 88_200, bits: 24,
              tracks: ["Walking Bass", "Smoke Rings", "Midnight Standard", "Coda"],
              art: { c, s in
                  c.setFillColor(rgb(0x121212)); c.fill(CGRect(x: 0, y: 0, width: s, height: s))
                  c.setFillColor(rgb(0x1E1E1E))
                  for x in stride(from: 0, to: s, by: 22) { c.fill(CGRect(x: x, y: 0, width: 1.5, height: s)) }
                  text(c, "III", size: 330, at: CGPoint(x: 70, y: 30), color: 0xD8CFBE)
              }, root: 98),
    DemoAlbum(title: "Tidewater", artist: "Keiko Aran", year: 2020, genre: "Ambient", container: .alac, rate: 44_100, bits: 16,
              tracks: ["Low Tide, Early", "Driftwood", "Sandbar", "Estuary", "High Water"],
              art: { c, s in
                  linear(c, s, [0x0D2A2B, 0x1F5A52, 0xB8C9A4], angle: 40)
                  radial(c, CGPoint(x: s * 0.7, y: s * 0.3), s * 0.5, [0xB8C9A4, 0x1F5A52])
              }, root: 146.8),
    DemoAlbum(title: "Rising Sun Suite", artist: "Oslo Chamber Players", year: 2018, genre: "Classical", container: .dsf, rate: 88_200, bits: 24,
              tracks: ["I. Aubade", "II. Meridian", "III. Afterglow"],
              art: { c, s in
                  c.setFillColor(rgb(0xE9E2D3)); c.fill(CGRect(x: 0, y: s * 0.38, width: s, height: s * 0.62))
                  c.setFillColor(rgb(0x1D1D1F)); c.fill(CGRect(x: 0, y: 0, width: s, height: s * 0.38))
                  c.setFillColor(rgb(0xB3342A)); c.fillEllipse(in: CGRect(x: s * 0.27, y: s * 0.24, width: s * 0.46, height: s * 0.46))
              }, root: 123.5, seconds: 18),
    DemoAlbum(title: "Violet Hours", artist: "Nadia Kerr", year: 2024, genre: "Electronic", container: .flac, rate: 48_000, bits: 24,
              tracks: ["Dusk Signal", "Violet", "Afterimage", "Neon Rain"],
              art: { c, s in
                  radial(c, CGPoint(x: s * 0.7, y: s * 0.7), s * 0.9, [0x4A3B6B, 0x1A1428, 0x0B0910])
                  c.setStrokeColor(rgb(0xFFFFFF, 0.06)); c.setLineWidth(3)
                  for r in stride(from: 30.0, to: 1200.0, by: 30) { c.strokeEllipse(in: CGRect(x: s * 0.7 - r, y: s * 0.7 - r, width: r * 2, height: r * 2)) }
              }, root: 116.5),
    DemoAlbum(title: "Null Set", artist: "Øresund", year: 2022, genre: "Minimal", container: .aiff, rate: 96_000, bits: 24,
              tracks: ["Empty Brackets", "Cardinality", "Zero"],
              art: { c, s in
                  linear(c, s, [0x2E2213, 0x8C6C3E, 0xC9B38A], angle: 45)
                  text(c, "Ø", size: 640, at: CGPoint(x: s * 0.23, y: s * 0.08), color: 0x140E06, serif: false)
              }, root: 87.3),
    DemoAlbum(title: "Evergreen Ridge", artist: "Harlan Moss", year: 2017, genre: "Folk", container: .flac, rate: 44_100, bits: 16,
              tracks: ["Trailhead", "Cedar Smoke", "Switchbacks", "Fire Lookout", "Alpenglow", "Descent"],
              art: { c, s in
                  linear(c, s, [0x0B1A10, 0x1F3B24, 0x6F8F5C], angle: 90)
                  c.setFillColor(rgb(0x0B1A10))
                  c.beginPath(); c.move(to: CGPoint(x: 0, y: 0))
                  for (x, y) in [(0.0, 0.1), (0.18, 0.38), (0.32, 0.22), (0.5, 0.5), (0.7, 0.26), (0.84, 0.42), (1.0, 0.1), (1.0, 0.0)] {
                      c.addLine(to: CGPoint(x: s * x, y: s * y))
                  }
                  c.closePath(); c.fillPath()
              }, root: 164.8),
    DemoAlbum(title: "Rhombus", artist: "Pale Geometry", year: 2025, genre: "Electronic", container: .wavpack, rate: 192_000, bits: 24,
              tracks: ["Vertex", "Four Sides", "Tessellation"],
              art: { c, s in
                  c.setFillColor(rgb(0x101012)); c.fill(CGRect(x: 0, y: 0, width: s, height: s))
                  c.setStrokeColor(rgb(0xCFC6B5)); c.setLineWidth(6)
                  c.move(to: CGPoint(x: s / 2, y: s * 0.12)); c.addLine(to: CGPoint(x: s * 0.88, y: s / 2))
                  c.addLine(to: CGPoint(x: s / 2, y: s * 0.88)); c.addLine(to: CGPoint(x: s * 0.12, y: s / 2)); c.closePath(); c.strokePath()
              }, root: 103.8),
    DemoAlbum(title: "Glass Harbour", artist: "Ines Moreau", year: 2016, genre: "Singer-Songwriter", container: .flac, rate: 176_400, bits: 24,
              tracks: ["Harbour Lights", "Glass", "Tender"],
              art: { c, s in radial(c, CGPoint(x: s * 0.3, y: s * 0.3), s, [0x9FB7C9, 0x3F5A73, 0x121A24]) },
              root: 138.6, bandLimitHz: 20_000),
    DemoAlbum(title: "Paper Letters", artist: "The Quiet Hours", year: 2015, genre: "Indie", container: .mp3, rate: 44_100, bits: 16,
              tracks: ["Postmark", "Ink", "Return to Sender", "Folded"],
              art: { c, s in
                  linear(c, s, [0x231A12, 0x5A4631, 0x231A12], angle: 45)
                  c.saveGState(); c.translateBy(x: s / 2, y: s / 2); c.rotate(by: 0.14)
                  c.setFillColor(rgb(0xE2D4B8)); c.fill(CGRect(x: -s * 0.2, y: -s * 0.2, width: s * 0.4, height: s * 0.4)); c.restoreGState()
              }, root: 155.6),
    DemoAlbum(title: "Live at the Meridian Room", artist: "Colm Hart", year: 2014, genre: "Jazz", container: .cueFLAC, rate: 44_100, bits: 16,
              tracks: ["Introduction", "Baritone Study No. 1", "Blue Hour", "Encore"],
              art: { c, s in
                  c.setFillColor(rgb(0x1A1A1C)); c.fill(CGRect(x: 0, y: 0, width: s, height: s))
                  c.setFillColor(rgb(0x2B2B2E))
                  for y in stride(from: 0, to: s, by: 36) { c.fill(CGRect(x: 0, y: y, width: s, height: 18)) }
                  text(c, "B", size: 420, at: CGPoint(x: s * 0.52, y: s * 0.42), color: 0xE7CD98, italic: true)
              }, root: 92.5, seconds: 20),
    DemoAlbum(title: "Ember Season", artist: "Lior Adams", year: 2024, genre: "Ambient", container: .flac, rate: 96_000, bits: 24,
              tracks: ["Kindling", "Ember", "Night Fire", "Ash & Morning"],
              art: { c, s in radial(c, CGPoint(x: s / 2, y: -s * 0.2), s * 1.1, [0xFF9A5A, 0x7A2E3B, 0x150A1C]) },
              root: 120),
]

// MARK: - Main

let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: nocturne-demo <output-folder>")
    exit(2)
}
let out = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("nocturne-demo-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }

func tag(_ url: URL, album: DemoAlbum, index: Int, title: String, cover: Data) {
    do {
        let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
        let md = file.metadata
        md.title = title
        md.artist = album.artist
        md.albumArtist = album.artist
        md.albumTitle = album.title
        md.genre = album.genre
        md.releaseDate = String(album.year)
        md.trackNumber = index + 1
        md.trackTotal = album.tracks.count
        md.discNumber = 1
        md.discTotal = 1
        md.composer = album.artist
        md.comment = "Nocturne demo content (synthesized; public domain)"
        md.attachPicture(AttachedPicture(imageData: cover, type: .frontCover))
        try file.writeMetadata()
    } catch {
        print("  ! could not tag \(url.lastPathComponent): \(error.localizedDescription)")
    }
}

for (ai, album) in albums.enumerated() {
    let folder = out.appendingPathComponent(album.artist).appendingPathComponent(album.title)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let cover = render(album.art)
    print("• \(album.artist) — \(album.title)")

    if album.container == .cueFLAC {
        // One continuous file + a CUE sheet.
        var channels: [[Double]] = [[], []]
        var starts: [Double] = []
        for (ti, _) in album.tracks.enumerated() {
            starts.append(Double(channels[0].count) / album.rate)
            let part = synthesize(rate: album.rate, seconds: album.seconds, root: album.root * (1 + Double(ti) * 0.06), seed: ai * 7 + ti, bandLimit: nil)
            channels[0] += part[0]; channels[1] += part[1]
        }
        let wav = temp.appendingPathComponent("live.wav")
        try writePCM(quantize(channels, bits: 16, padTo16: false), rate: album.rate, bits: 16, to: wav)
        let flac = folder.appendingPathComponent("\(album.title).flac")
        try? FileManager.default.removeItem(at: flac)
        try AudioConverter.convert(wav, to: flac)
        tag(flac, album: album, index: 0, title: album.title, cover: cover)
        var cue = "REM GENRE \"\(album.genre)\"\nREM DATE \(album.year)\nPERFORMER \"\(album.artist)\"\nTITLE \"\(album.title)\"\nFILE \"\(album.title).flac\" WAVE\n"
        for (ti, name) in album.tracks.enumerated() {
            let t = starts[ti]
            let cd = Int((t * 75).rounded())
            cue += String(format: "  TRACK %02d AUDIO\n    TITLE \"%@\"\n    INDEX 01 %02d:%02d:%02d\n", ti + 1, name, cd / 75 / 60, (cd / 75) % 60, cd % 75)
        }
        try cue.write(to: folder.appendingPathComponent("\(album.title).cue"), atomically: true, encoding: .utf8)
        try cover.write(to: folder.appendingPathComponent("cover.jpg"))
        continue
    }

    for (ti, name) in album.tracks.enumerated() {
        let signal = synthesize(rate: album.rate, seconds: album.seconds, root: album.root * (1 + Double(ti) * 0.06),
                                seed: ai * 7 + ti, bandLimit: album.bandLimitHz)
        let base = String(format: "%02d %@", ti + 1, name)
        let pad = album.padTo16Track == ti + 1
        let pcm = quantize(signal, bits: album.bits, padTo16: pad)
        let wav = temp.appendingPathComponent("\(ai)-\(ti).wav")
        try writePCM(pcm, rate: album.rate, bits: album.bits, to: wav)

        let dest: URL
        switch album.container {
        case .wav:
            dest = folder.appendingPathComponent(base + ".wav")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: wav, to: dest)
        case .aiff:
            dest = folder.appendingPathComponent(base + ".aiff")
            try? FileManager.default.removeItem(at: dest)
            try writePCM(pcm, rate: album.rate, bits: album.bits, to: dest, bigEndian: true)
        case .alac:
            dest = folder.appendingPathComponent(base + ".m4a")
            try? FileManager.default.removeItem(at: dest)
            try writePCM(pcm, rate: album.rate, bits: album.bits, to: dest, format: kAudioFormatAppleLossless)
        case .flac, .wavpack, .mp3:
            let ext = album.container == .flac ? "flac" : album.container == .wavpack ? "wv" : "mp3"
            dest = folder.appendingPathComponent(base + "." + ext)
            try? FileManager.default.removeItem(at: dest)
            try AudioConverter.convert(wav, to: dest)
        case .dsf:
            dest = folder.appendingPathComponent(base + ".dsf")
            try writeDSF(signal, pcmRate: album.rate, to: dest)
        case .cueFLAC:
            continue
        }
        tag(dest, album: album, index: ti, title: name, cover: cover)
    }
    if album.container == .dsf || album.container == .wav {
        try cover.write(to: folder.appendingPathComponent("cover.jpg"))
    }
}
print("Demo library written to \(out.path)")
