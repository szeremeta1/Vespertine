//
// Vespertine — the meters' printed faces (scale, numbers, the red zone), drawn with AppKit into masks the shader
// lights and colours.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit

enum VisualizerMeterFace {
    /// VU marks (dB) with numbers, and the minor ones between them.
    static let vuMarks: [Double] = [-20, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3]
    static let vuMinor: [Double] = [-15, -6, -4, -0.5, 0.5, 1.5, 2.5]
    /// The VU's second scale, in per cent of 0 VU.
    static let percent: [Double] = [0, 20, 40, 60, 80, 100]

    /// RGBA bytes the size of the drawable (top row first): red is the ink, green the red zone's ink.
    static func render(width w: Int, height h: Int, scale: CGFloat, kind: VisualizerMeterKind) -> [UInt8]? {
        let points = CGSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        let faces = VisualizerLayout.meterFaces(in: points)
        func mask(_ draw: (CGContext) -> Void) -> CGContext? {
            guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            c.translateBy(x: 0, y: CGFloat(h))
            c.scaleBy(x: scale, y: -scale)
            c.setFillColor(gray: 1, alpha: 1)
            c.setStrokeColor(gray: 1, alpha: 1)
            c.setLineCap(.butt)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
            draw(c)
            NSGraphicsContext.restoreGraphicsState()
            return c
        }
        guard let ink = mask({ c in for (i, f) in faces.enumerated() { drawInk(c, face: f, kind: kind, channel: i) } }),
              let red = mask({ c in if kind == .vu { for f in faces { drawRed(c, face: f) } } }),
              let inkData = ink.data, let redData = red.data else { return nil }
        let a = inkData.bindMemory(to: UInt8.self, capacity: w * h), b = redData.bindMemory(to: UInt8.self, capacity: w * h)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            bytes[4 * i] = a[i]
            bytes[4 * i + 1] = b[i]
        }
        return bytes
    }

    private static func arc(_ c: CGContext, face f: CGRect, from: Double, to: Double, radius: CGFloat, width: CGFloat) {
        let p = VisualizerLayout.pivot(of: f)
        // Angles from upright, clockwise, to Core Graphics' (from +x, here with y down).
        let a0 = VisualizerLayout.angle(travel: from) - .pi / 2, a1 = VisualizerLayout.angle(travel: to) - .pi / 2
        c.setLineWidth(width)
        c.addArc(center: p, radius: radius * f.height, startAngle: a0, endAngle: a1, clockwise: false)
        c.strokePath()
    }

    private static func tick(_ c: CGContext, face f: CGRect, travel: Double, from r0: CGFloat, to r1: CGFloat, width: CGFloat) {
        c.setLineWidth(width)
        c.move(to: VisualizerLayout.point(on: f, travel: travel, radius: r0))
        c.addLine(to: VisualizerLayout.point(on: f, travel: travel, radius: r1))
        c.strokePath()
    }

    private static func label(_ s: String, face f: CGRect, travel: Double, radius: CGFloat, size: CGFloat, weight: NSFont.Weight) {
        let text = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor.white,
        ])
        let at = VisualizerLayout.point(on: f, travel: travel, radius: radius)
        let b = text.size()
        text.draw(at: CGPoint(x: at.x - b.width / 2, y: at.y - b.height / 2))
    }

    private static func text(_ s: String, at p: CGPoint, size: CGFloat, weight: NSFont.Weight, centred: Bool = true) {
        let text = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor.white,
        ])
        let b = text.size()
        text.draw(at: CGPoint(x: centred ? p.x - b.width / 2 : p.x, y: p.y - b.height / 2))
    }

    private static func drawInk(_ c: CGContext, face f: CGRect, kind: VisualizerMeterKind, channel: Int) {
        let h = f.height, r = VisualizerLayout.scaleRadius
        let line = max(0.6, h * 0.006)
        switch kind {
        case .vu:
            let zero = VisualizerMeters.zeroVU
            arc(c, face: f, from: VisualizerMeters.vuTravel(decibels: -20), to: zero, radius: r, width: line)
            for db in vuMarks where db <= 0 {
                let t = VisualizerMeters.vuTravel(decibels: db)
                tick(c, face: f, travel: t, from: r, to: r + 0.06, width: line * 1.3)
                label(db == 0 ? "0" : "\(Int(-db))", face: f, travel: t, radius: r + 0.12, size: h * 0.085, weight: .medium)
            }
            for db in vuMinor where db < 0 {
                tick(c, face: f, travel: VisualizerMeters.vuTravel(decibels: db), from: r, to: r + 0.035, width: line)
            }
            // The signs at the ends of the scale, and the second scale (per cent) inside it.
            label("−", face: f, travel: 0.0, radius: r + 0.02, size: h * 0.1, weight: .medium)
            arc(c, face: f, from: 0, to: zero, radius: r - 0.075, width: line * 0.8)
            for p in percent {
                let t = zero * p / 100
                tick(c, face: f, travel: t, from: r - 0.075, to: r - 0.105, width: line * 0.8)
                label("\(Int(p))", face: f, travel: t, radius: r - 0.16, size: h * 0.045, weight: .regular)
            }
            text("VU", at: CGPoint(x: f.midX, y: f.minY + 0.6 * h), size: h * 0.13, weight: .semibold)
        case .ppm:
            arc(c, face: f, from: VisualizerMeters.ppmMark(1), to: VisualizerMeters.ppmMark(7), radius: r, width: line)
            for m in 1...7 {
                let t = VisualizerMeters.ppmMark(Double(m))
                tick(c, face: f, travel: t, from: r, to: r + 0.07, width: line * 1.6)
                label("\(m)", face: f, travel: t, radius: r + 0.14, size: h * 0.11, weight: .semibold)
                if m < 7 { tick(c, face: f, travel: VisualizerMeters.ppmMark(Double(m) + 0.5), from: r, to: r + 0.035, width: line) }
            }
        }
        text(channel == 0 ? "L" : "R", at: CGPoint(x: f.minX + 0.08 * h, y: f.minY + 0.1 * h), size: h * 0.065, weight: .semibold)
    }

    private static func drawRed(_ c: CGContext, face f: CGRect) {
        let r = VisualizerLayout.scaleRadius
        let zero = VisualizerMeters.zeroVU
        // The red zone: a band from 0 VU to the end, and its marks and numbers.
        arc(c, face: f, from: zero, to: 1, radius: r + 0.018, width: f.height * 0.036)
        for db in vuMarks where db > 0 {
            let t = VisualizerMeters.vuTravel(decibels: db)
            tick(c, face: f, travel: t, from: r, to: r + 0.06, width: max(0.6, f.height * 0.008))
            label("\(Int(db))", face: f, travel: t, radius: r + 0.12, size: f.height * 0.085, weight: .medium)
        }
        for db in vuMinor where db > 0 {
            tick(c, face: f, travel: VisualizerMeters.vuTravel(decibels: db), from: r, to: r + 0.035, width: max(0.5, f.height * 0.006))
        }
        label("+", face: f, travel: 1.07, radius: r + 0.02, size: f.height * 0.1, weight: .medium)
    }
}
