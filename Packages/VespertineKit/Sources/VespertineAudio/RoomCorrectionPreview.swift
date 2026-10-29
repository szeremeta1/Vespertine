//
// Vespertine — what a room correction should do, per speaker: the measurement (sixth-octave smoothed), the target at
// the measurement's level, and the predicted response with the filters applied. Predicted, not measured: only a new
// measurement with correction on shows what the room really does. Also drawn as a PNG for sharing.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct RoomCorrectionPreview: Sendable {
    public struct Channel: Sendable {
        public let speaker: RoomSpeaker
        public let frequencies: [Double]
        public let measuredDB: [Double]
        public let targetDB: [Double]
        /// Measured plus the filters, level-matched: the shared preamp (which only lowers the overall level) is left
        /// out, so the curve compares with the measurement and the target.
        public let predictedDB: [Double]
        public let bands: [EQBand]
        public let rollOffHz: Double?
        public let fitBand: ClosedRange<Double>?

        /// Root-mean-square distance from the target within the fit band (or 20 Hz to 500 Hz), measured and predicted,
        /// leaving out deep nulls (more than 6 dB under the target), which the design leaves alone.
        public var rmsErrorBeforeDB: Double { rmsError(measuredDB) }
        public var rmsErrorAfterDB: Double { rmsError(predictedDB) }

        private func rmsError(_ values: [Double]) -> Double {
            let band = fitBand ?? (rollOffHz ?? 20)...500
            let picked = frequencies.indices.filter { band.contains(frequencies[$0]) && measuredDB[$0] - targetDB[$0] >= -RoomFilterDesigner.nullDepthDB }
            guard !picked.isEmpty else { return 0 }
            return (picked.map { pow(values[$0] - targetDB[$0], 2) }.reduce(0, +) / Double(picked.count)).squareRoot()
        }
    }

    public let channels: [Channel]
    public let preampDB: Double
    public let targetName: String

    public init(design: RoomCorrectionDesign) {
        preampDB = design.preampDB
        targetName = design.options.target.name
        channels = RoomSpeaker.allCases.compactMap { speaker in
            guard let c = design.channels[speaker] else { return nil }
            let correction = c.correctionDB(at: c.measured.frequencies)
            return Channel(speaker: speaker, frequencies: c.measured.frequencies, measuredDB: c.measured.db, targetDB: c.targetDB,
                           predictedDB: zip(c.measured.db, correction).map { $0 + $1 }, bands: c.bands,
                           rollOffHz: c.rollOffHz, fitBand: c.fitBand)
        }
    }

    /// From a stored profile that kept its measurement and design options; nil for one that didn't.
    public init?(profile: RoomProfile) {
        guard let measured = profile.measured, !measured.isEmpty else { return nil }
        let options = profile.designOptions ?? .default
        preampDB = profile.filters.preampDB
        targetName = options.target.name
        channels = RoomSpeaker.allCases.compactMap { speaker in
            guard let raw = measured[speaker] else { return nil }
            let smooth = raw.smoothed(octaves: options.smoothingOctaves)
            let bands = profile.filters.channels[speaker] ?? []
            let correction = EQPreset(name: "", bands: bands).responseDB(at: smooth.frequencies, sampleRate: RoomFilterDesigner.designRate)
            let target = RoomFilterDesigner.targetDB(for: smooth, options: options)
            return Channel(speaker: speaker, frequencies: smooth.frequencies, measuredDB: smooth.db, targetDB: target,
                           predictedDB: zip(smooth.db, correction).map { $0 + $1 }, bands: bands,
                           rollOffHz: nil, fitBand: nil)
        }
    }

    // MARK: PNG

    private static let colours: [RoomSpeaker: (CGFloat, CGFloat, CGFloat)] = [.left: (0.55, 0.78, 1), .right: (1, 0.62, 0.5)]

    /// One panel per speaker: measured (thin), target (dashed), predicted (bold), with the filter list beside it.
    public func renderPNG(title: String) throws -> Data {
        let width = 1600, panelH = 520, header = 90
        let height = header + panelH * max(1, channels.count) + 20
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RoomCaptureError.unreadableFile
        }
        context.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        func text(_ s: String, at p: CGPoint, size: CGFloat = 18, alpha: CGFloat = 0.85, colour: (CGFloat, CGFloat, CGFloat) = (1, 1, 1),
                  centred: Bool = false, mono: Bool = false) {
            let font = CTFontCreateWithName((mono ? "Menlo" : "Helvetica Neue") as CFString, size, nil)
            let attributes: [CFString: Any] = [kCTFontAttributeName: font,
                                               kCTForegroundColorAttributeName: CGColor(red: colour.0, green: colour.1, blue: colour.2, alpha: alpha)]
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, s as CFString, attributes as CFDictionary))
            let w = CTLineGetBoundsWithOptions(line, []).width
            context.textPosition = CGPoint(x: centred ? p.x - w / 2 : p.x, y: p.y)
            CTLineDraw(line, context)
        }

        text(title, at: CGPoint(x: 40, y: Double(height) - 46), size: 26, alpha: 0.95)
        text("Predicted, not measured. Thin: measured (1/6-octave smoothed). Dashed: target (\(targetName)). Bold: predicted after correction, level-matched (preamp \(String(format: "%.1f", preampDB)) dB not shown).",
             at: CGPoint(x: 40, y: Double(height) - 76), size: 16, alpha: 0.7)

        let lo = 20.0, hi = 20_000.0
        let all = channels.flatMap { $0.measuredDB + $0.predictedDB }
        let yMax = max(10, ceil((all.max() ?? 10) / 5) * 5), yMin = max(-40, min(-20, floor((all.min() ?? -20) / 5) * 5))
        for (n, channel) in channels.enumerated() {
            let top = Double(height - header - n * panelH) - 20
            let bottom = top - Double(panelH) + 60
            let left = 80.0, right = Double(width) - 400
            func x(_ hz: Double) -> Double { left + Foundation.log(hz / lo) / Foundation.log(hi / lo) * (right - left) }
            func y(_ db: Double) -> Double { bottom + (db - yMin) / (yMax - yMin) * (top - bottom) }
            context.setLineDash(phase: 0, lengths: [])
            context.setLineWidth(1)
            for hz in [20.0, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000] {
                context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
                context.move(to: CGPoint(x: x(hz), y: bottom)); context.addLine(to: CGPoint(x: x(hz), y: top)); context.strokePath()
                text(hz >= 1_000 ? "\(Int(hz / 1_000))k" : "\(Int(hz))", at: CGPoint(x: x(hz), y: bottom - 24), size: 15, centred: true)
            }
            var db = yMin
            while db <= yMax {
                context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: db == 0 ? 0.3 : 0.12))
                context.move(to: CGPoint(x: left, y: y(db))); context.addLine(to: CGPoint(x: right, y: y(db))); context.strokePath()
                text("\(Int(db))", at: CGPoint(x: left - 44, y: y(db) - 6), size: 15)
                db += 5
            }
            let c = Self.colours[channel.speaker] ?? (0.8, 0.8, 0.8)
            text(channel.speaker.rawValue.capitalized, at: CGPoint(x: left + 10, y: top - 26), size: 22, alpha: 1, colour: c)
            context.saveGState()
            context.clip(to: CGRect(x: left, y: bottom, width: right - left, height: top - bottom))
            for (values, width, alpha, dash) in [(channel.targetDB, 1.5, 0.7, true), (channel.measuredDB, 1.5, 0.55, false),
                                                 (channel.predictedDB, 3.5, 1.0, false)] as [([Double], CGFloat, CGFloat, Bool)] {
                context.setStrokeColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: alpha))
                context.setLineWidth(width)
                context.setLineJoin(.round)
                context.setLineDash(phase: 0, lengths: dash ? [8, 6] : [])
                var started = false
                for (j, hz) in channel.frequencies.enumerated() where hz >= lo && hz <= hi {
                    let p = CGPoint(x: x(hz), y: y(values[j]))
                    if started { context.addLine(to: p) } else { context.move(to: p); started = true }
                }
                context.strokePath()
            }
            context.restoreGState()
            context.setLineDash(phase: 0, lengths: [])
            // Filter list.
            var ty = top - 26
            text("Filters (peaking)", at: CGPoint(x: right + 30, y: ty), size: 17, alpha: 0.9)
            ty -= 26
            text("   Hz      dB      Q", at: CGPoint(x: right + 30, y: ty), size: 14, alpha: 0.6, mono: true)
            for b in channel.bands {
                ty -= 22
                text(String(format: "%6.1f  %+5.1f  %5.2f", b.frequency, b.gainDB, b.q), at: CGPoint(x: right + 30, y: ty), size: 14, alpha: 0.85, mono: true)
            }
            ty -= 34
            text(String(format: "RMS deviation from target, %@:", channel.fitBand.map { String(format: "%.0f–%.0f Hz", $0.lowerBound, $0.upperBound) } ?? "fit band"),
                 at: CGPoint(x: right + 30, y: ty), size: 14, alpha: 0.7)
            ty -= 22
            text(String(format: "%.1f dB measured → %.1f dB predicted", channel.rmsErrorBeforeDB, channel.rmsErrorAfterDB),
                 at: CGPoint(x: right + 30, y: ty), size: 14, alpha: 0.85)
            if let r = channel.rollOffHz {
                ty -= 22
                text(String(format: "Roll-off (−6 dB): %.0f Hz, no boost below", r), at: CGPoint(x: right + 30, y: ty), size: 14, alpha: 0.7)
            }
        }
        guard let image = context.makeImage() else { throw RoomCaptureError.unreadableFile }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw RoomCaptureError.unreadableFile }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RoomCaptureError.unreadableFile }
        return data as Data
    }
}

/// What a profile's correction itself does per speaker: its bands, level and preamp, plus a measured filter's
/// magnitude. For profiles with no measurement to draw a before and after from (imported ones).
public struct RoomCorrectionCurves: Sendable {
    public struct Channel: Sendable {
        public let speaker: RoomSpeaker
        public let frequencies: [Double]
        public let db: [Double]
    }

    public let channels: [Channel]

    /// 20 Hz to 20 kHz, twelve points an octave.
    public static let frequencies: [Double] = (0...120).map { 20 * pow(2, Double($0) / 12) }

    /// Reads measured filters from `impulseDirectory` (slow for long ones: build it off the main thread).
    public init(profile: RoomProfile, impulseDirectory: URL = RoomImpulse.defaultDirectory) {
        let playback = RoomCorrectionPlayback(profile: profile, impulseDirectory: impulseDirectory)
        let rate = RoomFilterDesigner.designRate
        let freqs = Self.frequencies
        channels = profile.channelMap.entries.sorted { $0.output < $1.output }.compactMap { entry in
            guard entry.output < playback.channels.count else { return nil }
            var db = playback.responseDB(channel: entry.output, at: freqs, sampleRate: rate)
            if let impulse = playback.channels[entry.output].impulse, let filter = impulse.responseDB(at: freqs, in: impulseDirectory) {
                db = zip(db, filter).map { $0 + $1 }
            }
            return Channel(speaker: entry.speaker, frequencies: freqs, db: db)
        }
    }
}
