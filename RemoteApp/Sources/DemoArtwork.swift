//
// Vespertine Remote: covers for the demo Mac's made-up albums, drawn on the phone (soft gradients, no real art).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import UIKit

enum DemoArtwork {
    static func png(key: String, size: Int) -> Data? {
        let side = CGFloat(min(max(size, 64), 1200))
        let seed = key.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value }
        let hue = CGFloat(seed % 360) / 360
        let top = UIColor(hue: hue, saturation: 0.55, brightness: 0.75, alpha: 1)
        let bottom = UIColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.25, alpha: 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let image = renderer.image { context in
            let colors = [top.cgColor, bottom.cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
            UIColor(white: 1, alpha: 0.18).setFill()
            let radius = side * (0.18 + CGFloat(seed % 20) / 100)
            let center = CGPoint(x: side * (0.3 + CGFloat(seed % 40) / 100), y: side * 0.62)
            UIBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
        }
        return image.pngData()
    }
}
