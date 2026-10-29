//
// Vespertine — a measured speaker's magnitude response, with the microphone's calibration applied, and its CSV and
// PNG renderings. Offline analysis of an accepted recording; nothing here touches playback.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct RoomMagnitudeResponse: Sendable {
    public let frequencies: [Double]
    /// Level of the recovered impulse response relative to the unit-amplitude stimulus (dB), as recorded.
    public let rawDB: [Double]
    /// What the calibration file says to add at each frequency (zero without a file).
    public let micCompensationDB: [Double]
    public let calibratedDB: [Double]
    /// `calibratedDB` with its mean over 200 Hz to 2 kHz taken out, for plotting.
    public let normalisedDB: [Double]
    public let clockDriftPPM: Double
    /// The calibrated level over 200 Hz to 2 kHz (dB): how loud this speaker is at the microphone.
    public let levelDB: Double
    /// When the speaker's sound arrived, in milliseconds after the speaker that played the timing references (0 when
    /// it played them itself, give or take the filters' own delay, which every speaker shares).
    public let arrivalMs: Double

    /// Points per octave of the log frequency grid.
    public static let pointsPerOctave = 24.0

    public static func compute(recording: RoomRecording, calibration: MicCalibration?) throws -> RoomMagnitudeResponse {
        let layout = recording.request.layout
        let analysis = try recording.analyse()
        let impulse = try layout.sweep.recover(recording: analysis.sweepSegment)
        let band = layout.sweep.reliableBand
        let count = Int((Foundation.log2(band.upperBound / band.lowerBound) * pointsPerOctave).rounded(.down)) + 1
        let frequencies = (0..<count).map { band.lowerBound * pow(2, Double($0) / pointsPerOctave) }
        let scale = 20 * Foundation.log10(layout.level)
        let raw = frequencies.map { impulse.response(at: $0).magnitudeDB - scale }
        let compensation = frequencies.map { calibration?.compensationDB(at: $0) ?? 0 }
        let calibrated = zip(raw, compensation).map { $0 + $1 }
        let centre = frequencies.indices.filter { frequencies[$0] >= 200 && frequencies[$0] <= 2_000 }
        let basis = centre.isEmpty ? Array(calibrated.indices) : centre
        let mean = basis.map { calibrated[$0] }.reduce(0, +) / Double(max(1, basis.count))
        let arrival: Double = (impulse.arrivalSamples - Double(analysis.leadSamples)) / layout.sampleRate * 1000
        return RoomMagnitudeResponse(frequencies: frequencies, rawDB: raw, micCompensationDB: compensation, calibratedDB: calibrated,
                                     normalisedDB: calibrated.map { $0 - mean }, clockDriftPPM: analysis.drift.ppm,
                                     levelDB: mean, arrivalMs: arrival)
    }

    /// `normalisedDB` averaged in power over a sixth of an octave either side, for reading the shape through the ripple.
    public var smoothedDB: [Double] {
        let half = 1.0 / 12
        return frequencies.indices.map { i in
            let lo = frequencies[i] * pow(2, -half), hi = frequencies[i] * pow(2, half)
            var sum = 0.0, n = 0.0
            for j in frequencies.indices where frequencies[j] >= lo && frequencies[j] <= hi {
                sum += pow(10, normalisedDB[j] / 10)
                n += 1
            }
            return 10 * Foundation.log10(max(sum / max(n, 1), 1e-30))
        }
    }

    public var csv: String {
        var out = "frequency_hz,raw_db,mic_compensation_db,calibrated_db,calibrated_normalised_db\n"
        for i in frequencies.indices {
            out += String(format: "%.3f,%.4f,%.4f,%.4f,%.4f\n", frequencies[i], rawDB[i], micCompensationDB[i], calibratedDB[i], normalisedDB[i])
        }
        return out
    }
}

public enum RoomResponseFiles {
    public struct Written: Sendable {
        public let csv: [URL]
        public let plot: URL
    }

    /// `<name>-<speaker>.csv` for each speaker and `<name>.png` with all of them on one plot.
    public static func write(_ responses: [RoomSpeaker: RoomMagnitudeResponse], to folder: URL, name: String) throws -> Written {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var csvs: [URL] = []
        let ordered = RoomSpeaker.allCases.compactMap { s in responses[s].map { (s, $0) } }
        for (speaker, response) in ordered {
            let url = folder.appendingPathComponent("\(name)-\(speaker.rawValue).csv")
            try response.csv.write(to: url, atomically: true, encoding: .utf8)
            csvs.append(url)
        }
        let plot = folder.appendingPathComponent("\(name).png")
        try renderPNG(ordered.map { ($0.rawValue, $1) }).write(to: plot, options: .atomic)
        return Written(csv: csvs, plot: plot)
    }

    private static let colours: [(CGFloat, CGFloat, CGFloat)] = [(0.55, 0.78, 1), (1, 0.62, 0.5), (0.6, 0.95, 0.6), (1, 0.85, 0.4), (0.85, 0.65, 1), (0.6, 0.9, 0.9)]

    static func renderPNG(_ curves: [(String, RoomMagnitudeResponse)]) throws -> Data {
        let width = 1400, height = 800
        let left = 90.0, right = 40.0, top = 70.0, bottom = 70.0
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RoomCaptureError.unreadableFile
        }
        let plotW = Double(width) - left - right, plotH = Double(height) - top - bottom
        context.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let lo = 20.0, hi = 20_000.0
        let all = curves.flatMap { $0.1.smoothedDB }
        let yMax = max(10, ceil((all.max() ?? 10) / 5) * 5 + 5), yMin = min(-25, floor((all.min() ?? -25) / 5) * 5 - 5)
        func x(_ hz: Double) -> Double { left + Foundation.log(hz / lo) / Foundation.log(hi / lo) * plotW }
        func y(_ db: Double) -> Double { bottom + (db - yMin) / (yMax - yMin) * plotH }

        func text(_ s: String, at p: CGPoint, size: CGFloat = 18, alpha: CGFloat = 0.8, centred: Bool = false) {
            let font = CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
            let attributes: [CFString: Any] = [kCTFontAttributeName: font,
                                               kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: alpha)]
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, s as CFString, attributes as CFDictionary))
            let w = CTLineGetBoundsWithOptions(line, []).width
            context.textPosition = CGPoint(x: centred ? p.x - w / 2 : p.x, y: p.y)
            CTLineDraw(line, context)
        }

        context.setLineWidth(1)
        for hz in [20.0, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000] {
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
            context.move(to: CGPoint(x: x(hz), y: bottom)); context.addLine(to: CGPoint(x: x(hz), y: Double(height) - top)); context.strokePath()
            text(hz >= 1_000 ? "\(Int(hz / 1_000))k" : "\(Int(hz))", at: CGPoint(x: x(hz), y: bottom - 28), size: 16, centred: true)
        }
        var db = yMin
        while db <= yMax {
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: db == 0 ? 0.3 : 0.12))
            context.move(to: CGPoint(x: left, y: y(db))); context.addLine(to: CGPoint(x: Double(width) - right, y: y(db))); context.strokePath()
            text("\(Int(db))", at: CGPoint(x: left - 44, y: y(db) - 6), size: 16)
            db += 5
        }
        text("Measured response, microphone-calibrated (bold: 1/6-octave smoothing), 0 dB = mean 200 Hz to 2 kHz", at: CGPoint(x: left, y: Double(height) - 42), size: 22, alpha: 0.95)
        text("dB", at: CGPoint(x: 30, y: Double(height) - top - 4), size: 16)
        context.saveGState()
        context.clip(to: CGRect(x: left, y: bottom, width: plotW, height: plotH))
        for (i, (_, response)) in curves.enumerated() {
            let c = colours[i % colours.count]
            // The measured points faintly, the sixth-octave smoothing over them.
            for (values, width, alpha) in [(response.normalisedDB, 1.0, 0.35), (response.smoothedDB, 3.0, 1.0)] as [([Double], CGFloat, CGFloat)] {
                context.setStrokeColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: alpha))
                context.setLineWidth(width)
                context.setLineJoin(.round)
                for (j, hz) in response.frequencies.enumerated() {
                    let p = CGPoint(x: x(hz), y: y(values[j]))
                    j == 0 ? context.move(to: p) : context.addLine(to: p)
                }
                context.strokePath()
            }
        }
        context.restoreGState()
        for (i, (name, _)) in curves.enumerated() {
            let c = colours[i % colours.count]
            context.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
            context.fill(CGRect(x: Double(width) - right - 150, y: Double(height) - 44 - Double(i) * 26, width: 16, height: 16))
            text(name, at: CGPoint(x: Double(width) - right - 124, y: Double(height) - 44 - Double(i) * 26), size: 18)
        }
        guard let image = context.makeImage() else { throw RoomCaptureError.unreadableFile }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw RoomCaptureError.unreadableFile }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RoomCaptureError.unreadableFile }
        return data as Data
    }
}
