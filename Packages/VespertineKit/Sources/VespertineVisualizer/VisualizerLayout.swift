//
// Vespertine — where the scope's screen and the meters sit in the window, shared by the shaders (in pixels) and the
// labels drawn over them (in points). Points, y down, as the overlay draws.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics

enum VisualizerLayout {
    /// Room kept at the bottom for the song's title.
    static let titleRoom: CGFloat = 100
    static let top: CGFloat = 40

    /// The goniometer's circle (full scale on its edge) and the correlation bar under it.
    static func goniometer(in size: CGSize) -> (centre: CGPoint, radius: CGFloat, bar: CGRect) {
        let barRoom: CGFloat = 46
        let diameter = max(40, min(size.width - 80, size.height - top - titleRoom - barRoom))
        let centre = CGPoint(x: size.width / 2, y: top + diameter / 2)
        let width = min(diameter, 360)
        let bar = CGRect(x: size.width / 2 - width / 2, y: top + diameter + 20, width: width, height: 6)
        return (centre, diameter / 2, bar)
    }

    /// The oscilloscope's screen: 10 by 8 square divisions, as large as fits.
    static func oscilloscope(in size: CGSize) -> CGRect {
        let area = CGRect(x: 48, y: top + 4, width: max(40, size.width - 96), height: max(32, size.height - top - 4 - titleRoom))
        let division = min(area.width / 10, area.height / 8)
        return CGRect(x: area.midX - division * 5, y: area.midY - division * 4, width: division * 10, height: division * 8)
    }

    /// The width over the height of a meter's face.
    static let meterAspect: CGFloat = 1.55
    /// The bezel round each face, as a fraction of the face's height.
    static let bezel: CGFloat = 0.07

    /// The two meters' faces (left, right): side by side when the window is wide enough, else one above the other.
    static func meterFaces(in size: CGSize) -> [CGRect] {
        let area = CGRect(x: 32, y: top, width: max(40, size.width - 64), height: max(40, size.height - top - titleRoom))
        let gap: CGFloat = 30
        let a = meterAspect, b = 1 + 2 * bezel
        // Side by side: each face's height, bezel included in what has to fit.
        let sideHeight = min((area.width - gap) / 2 / (a + 2 * bezel), area.height / b)
        let stackedHeight = min((area.height - gap) / 2 / b, area.width / (a + 2 * bezel))
        if sideHeight >= stackedHeight {
            let h = max(10, sideHeight), w = h * a
            let total = 2 * w + gap + 4 * bezel * h
            let x0 = area.midX - total / 2 + bezel * h
            let y = area.midY - h / 2
            return [CGRect(x: x0, y: y, width: w, height: h), CGRect(x: x0 + w + gap + 2 * bezel * h, y: y, width: w, height: h)]
        } else {
            let h = max(10, stackedHeight), w = h * a
            let total = 2 * h + gap + 4 * bezel * h
            let y0 = area.midY - total / 2 + bezel * h
            let x = area.midX - w / 2
            return [CGRect(x: x, y: y0, width: w, height: h), CGRect(x: x, y: y0 + h + gap + 2 * bezel * h, width: w, height: h)]
        }
    }

    // A meter's geometry, as fractions of its face's height: the needle's pivot (below the face, hidden by the cover),
    // the scale's radius, how far the needle swings each way, and the cover over the pivot.
    static let pivotDrop: CGFloat = 1.25
    static let scaleRadius: CGFloat = 0.95
    static let swing: CGFloat = 42 * .pi / 180
    static let coverRadius: CGFloat = 0.5

    /// The pivot of a face's needle.
    static func pivot(of face: CGRect) -> CGPoint { CGPoint(x: face.midX, y: face.minY + pivotDrop * face.height) }

    /// The needle's angle from upright (clockwise) for a travel of 0…1.
    static func angle(travel: Double) -> CGFloat { -swing + 2 * swing * CGFloat(travel) }

    /// A point on a face at `radius` (fraction of its height) from the pivot, at the angle for `travel`.
    static func point(on face: CGRect, travel: Double, radius: CGFloat) -> CGPoint {
        let p = pivot(of: face), a = angle(travel: travel), r = radius * face.height
        return CGPoint(x: p.x + r * sin(a), y: p.y - r * cos(a))
    }
}
