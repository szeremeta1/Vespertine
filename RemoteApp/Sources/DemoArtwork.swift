//
// Vespertine Remote: covers for the demo Mac's made-up albums, drawn on the phone (shapes and gradients, no real art).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import UIKit

enum DemoArtwork {
    /// A steady number from an album key (FNV-1a), so each album keeps its cover.
    nonisolated static func seed(_ key: String) -> UInt32 {
        key.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }

    static func png(key: String, size: Int) -> Data? {
        let side = CGFloat(min(max(size, 64), 1200))
        let seed = seed(key)
        func pick(_ shift: UInt32, _ count: UInt32) -> Int { Int((seed >> shift) % count) }
        // Hues spread round the wheel, kept dusky.
        let hue = CGFloat((seed >> 3) % 360) / 360
        let second = (hue + [0.08, 0.5, 0.33, 0.92][pick(11, 4)]).truncatingRemainder(dividingBy: 1)
        let top = UIColor(hue: hue, saturation: 0.5, brightness: 0.72, alpha: 1)
        let bottom = UIColor(hue: second, saturation: 0.62, brightness: 0.22, alpha: 1)
        let ink = UIColor(hue: second, saturation: 0.25, brightness: 0.95, alpha: 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let image = renderer.image { context in
            let cg = context.cgContext
            let colors = [top.cgColor, bottom.cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
            let across = pick(5, 2) == 0
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: across ? side : 0, y: side), options: [])
            switch pick(17, 5) {
            case 0:
                // A low sun over a horizon.
                let radius = side * (0.2 + CGFloat(pick(8, 12)) / 100)
                let center = CGPoint(x: side * (0.35 + CGFloat(pick(20, 30)) / 100), y: side * 0.6)
                ink.withAlphaComponent(0.75).setFill()
                UIBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
                bottom.withAlphaComponent(0.92).setFill()
                UIRectFill(CGRect(x: 0, y: side * 0.66, width: side, height: side * 0.34))
            case 1:
                // Rings.
                let center = CGPoint(x: side * (0.3 + CGFloat(pick(8, 40)) / 100), y: side * (0.3 + CGFloat(pick(20, 40)) / 100))
                for ring in 1...7 {
                    let radius = side * 0.09 * CGFloat(ring)
                    let path = UIBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    path.lineWidth = side * 0.012
                    ink.withAlphaComponent(0.55 - CGFloat(ring) * 0.06).setStroke()
                    path.stroke()
                }
            case 2:
                // Slanted bands.
                cg.saveGState()
                cg.translateBy(x: side / 2, y: side / 2)
                cg.rotate(by: .pi / 180 * CGFloat(20 + pick(8, 50)))
                for band in 0..<4 {
                    ink.withAlphaComponent(0.12 + CGFloat(band) * 0.09).setFill()
                    UIRectFill(CGRect(x: -side, y: -side * 0.42 + CGFloat(band) * side * 0.2, width: side * 2, height: side * 0.09))
                }
                cg.restoreGState()
            case 3:
                // A field of dots, thinning out.
                let count = 6 + pick(8, 3)
                let step = side / CGFloat(count + 1)
                for row in 1...count {
                    for column in 1...count {
                        let radius = step * 0.3 * CGFloat(column + row) / CGFloat(count * 2)
                        ink.withAlphaComponent(0.6).setFill()
                        UIBezierPath(ovalIn: CGRect(x: step * CGFloat(column) - radius, y: step * CGFloat(row) - radius, width: radius * 2, height: radius * 2)).fill()
                    }
                }
            default:
                // A crescent.
                let radius = side * 0.27
                let center = CGPoint(x: side * 0.5, y: side * 0.46)
                let disc = UIBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                let offset = radius * (0.3 + CGFloat(pick(8, 20)) / 100)
                disc.append(UIBezierPath(ovalIn: CGRect(x: center.x - radius + offset, y: center.y - radius - offset * 0.5, width: radius * 2, height: radius * 2)).reversing())
                ink.withAlphaComponent(0.8).setFill()
                disc.usesEvenOddFillRule = true
                disc.fill()
            }
            // A soft vignette, so covers sit together.
            if let shade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [UIColor.clear.cgColor, UIColor(white: 0, alpha: 0.28).cgColor] as CFArray, locations: [0.55, 1]) {
                cg.drawRadialGradient(shade, startCenter: CGPoint(x: side / 2, y: side / 2), startRadius: 0,
                                      endCenter: CGPoint(x: side / 2, y: side / 2), endRadius: side * 0.75, options: [])
            }
        }
        return image.pngData()
    }
}
