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

    // MARK: Vinyl

    // The turntable in the record's own units (y up, the record's centre at 0): the record, the platter, the ring of
    // light round it, the label, and the sleeve. Where the sleeve rests follows MD Vinyl's (Alex's references): in front,
    // upright, a touch larger than the record (as an LP's is) and level with it, its right edge through the record's
    // centre, so the record shows half out of it; behind, the same sleeve further left, turned 4° anticlockwise, the
    // record lying over its right edge.
    static let recordRadius: CGFloat = 0.86
    static let labelRadius: CGFloat = 0.31
    static let platterRadius: CGFloat = 0.95
    static let sleeveHalf: CGFloat = 0.883
    /// The sleeve's centre in front (`place` 0) and behind (1), and how far it's turned behind (radians, anticlockwise).
    static let sleeveCentre: CGFloat = -0.883
    static let sleeveBehindCentre: CGFloat = -1.385
    static let sleeveBehindTilt: CGFloat = 4 * .pi / 180
    /// How far right the tonearm reaches (its pivot, plate and counterweight), and the ring of light either side.
    static let armReach: CGFloat = 1.22
    static let ringReach: CGFloat = 1.0

    /// The song's title and artist, bottom left (see `VisualizerOverlay`): the height the sleeve keeps clear of, in points.
    static let vinylTitleRoom: CGFloat = 86

    /// Where the sleeve rests (`place` 0 in front, 1 behind, between the two on the way), before it's slid `offset`
    /// to the left or right: its centre and how far it's turned.
    static func sleeveRest(place: CGFloat) -> (x: CGFloat, tilt: CGFloat) {
        let p = min(max(place.isFinite ? place : 0, 0), 1)
        return (sleeveCentre + (sleeveBehindCentre - sleeveCentre) * p, sleeveBehindTilt * p)
    }

    /// How far the sleeve reaches either side of its centre, turned by `tilt` (its corners).
    static func sleeveReach(tilt: CGFloat) -> CGFloat { sleeveHalf * (cos(tilt) + abs(sin(tilt))) }

    /// Where the record's centre is and how many pixels (or points) one of its units is, in a window of `size`. Without
    /// a sleeve (`sleeve` 0) it's as it always was; with one (1) the whole turntable moves right, and shrinks if it must,
    /// so that the sleeve on its left, the record and the tonearm sit together in the middle of the window, as in MD
    /// Vinyl, with the sleeve's bottom above the song's title (`titleRoom`, in the same units as `size`; 0 with no
    /// title). In between while the sleeve comes or goes; `place` is where it rests (0 in front, 1 behind).
    static func vinyl(in size: CGSize, tonearm: Bool, sleeve: CGFloat, place: CGFloat = 0,
                      titleRoom: CGFloat = 0) -> (centre: CGPoint, unit: CGFloat) {
        let w = max(size.width, 1), h = max(size.height, 1)
        let unit0 = 0.5 * min(w, h) * 0.92
        let centre0 = CGPoint(x: w * 0.5 - (tonearm ? unit0 * 0.18 * min(1, w / h) : 0), y: h * 0.5)
        let t = min(max(sleeve.isFinite ? sleeve : 0, 0), 1)
        guard t > 0 else { return (centre0, unit0) }
        let rest = sleeveRest(place: place), reach = sleeveReach(tilt: rest.tilt)
        let left = rest.x - reach - 0.04, right = tonearm ? armReach : ringReach
        let room = max(0, titleRoom.isFinite ? titleRoom : 0), edge = 0.02 * h
        // The ring of light reaches 1 above and below the centre, the sleeve `reach` below it.
        let unit1 = max(1, min(unit0, 0.96 * w / (right - left), (h - room - edge) / (1 + reach)))
        let centre1 = CGPoint(x: w * 0.5 - (left + right) * 0.5 * unit1, y: min(h * 0.5, h - room - reach * unit1))
        // Eased, so the turntable starts and stops moving gently.
        let e = t * t * (3 - 2 * t)
        return (CGPoint(x: centre0.x + (centre1.x - centre0.x) * e, y: centre0.y + (centre1.y - centre0.y) * e), unit0 + (unit1 - unit0) * e)
    }

    /// Whether a click at `point` (y down, in the same units as `size`) is on the album cover: on the record's label,
    /// or on as much of the sleeve as shows.
    static func vinylCoverHit(_ point: CGPoint, in size: CGSize, tonearm: Bool, pose: VisualizerCoverPose, titleRoom: CGFloat = 0) -> Bool {
        let (centre, unit) = vinyl(in: size, tonearm: tonearm, sleeve: CGFloat(pose.layout), place: CGFloat(pose.place),
                                   titleRoom: titleRoom)
        let q = CGPoint(x: (point.x - centre.x) / unit, y: -(point.y - centre.y) / unit)
        let r = (q.x * q.x + q.y * q.y).squareRoot()
        if r <= labelRadius { return true }
        guard pose.opacity > 0.5 else { return false }
        // Into the sleeve's own frame: from its centre, turned back.
        let rest = sleeveRest(place: CGFloat(pose.place))
        let dx = q.x - (rest.x + CGFloat(pose.offset)), c = cos(rest.tilt), s = sin(rest.tilt)
        let onSleeve = abs(c * dx + s * q.y) <= sleeveHalf && abs(-s * dx + c * q.y) <= sleeveHalf
        // Behind the record, only the part the record doesn't cover.
        return onSleeve && (pose.front > 0.5 || r > recordRadius)
    }
}
