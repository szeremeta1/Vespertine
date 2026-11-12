//
// Vespertine Remote: the turning record in Now Playing: how far it has turned and where the tonearm rests. Numbers only.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

nonisolated enum VinylGeometry {
    /// 33⅓ turns a minute.
    static let degreesPerSecond = 200.0

    /// The record's angle `position` seconds into the song: it turns with the music, so a pause holds it still and
    /// a seek puts it where it would have been.
    static func rotation(position: Double) -> Double {
        guard position.isFinite, position > 0 else { return 0 }
        return (position * degreesPerSecond).truncatingRemainder(dividingBy: 360)
    }

    /// The label's share of the record's width, and where the grooves start and end (shares of the radius).
    static let labelShare = 0.4
    static let grooveOuter = 0.96
    static let grooveInner = 0.46

    /// Where the needle is, as a share of the record's radius: the outer groove at the start, the inner at the end.
    static func needleRadius(progress: Double) -> Double {
        let p = max(0, min(1, progress.isFinite ? progress : 0))
        return grooveOuter - (grooveOuter - grooveInner) * p
    }

    /// The tonearm's angle in degrees from its rest (0: parked beside the record). The arm pivots at `pivot`
    /// (in record radii from the centre, x right, y down) and its needle is `length` radii from the pivot.
    static func tonearmAngle(progress: Double, pivot: (x: Double, y: Double) = armPivot, length: Double = armLength) -> Double {
        angle(toRadius: needleRadius(progress: progress), pivot: pivot, length: length) - restAngle(pivot: pivot, length: length)
    }

    static let armPivot = (x: 1.02, y: -0.98)
    static let armLength = 1.22
    /// The parked arm's needle sits this far out (radii), clear of the record.
    static let restRadius = 1.1

    /// The direction (degrees clockwise from straight down) the arm points when its needle is `radius` from the centre.
    static func angle(toRadius radius: Double, pivot: (x: Double, y: Double), length: Double) -> Double {
        // Triangle: centre–pivot (d), pivot–needle (length), centre–needle (radius).
        let d = (pivot.x * pivot.x + pivot.y * pivot.y).squareRoot()
        let cosine = max(-1, min(1, (d * d + length * length - radius * radius) / (2 * d * length)))
        let atPivot = acos(cosine) * 180 / .pi
        // The direction from the pivot to the centre, clockwise from straight down.
        let toCentre = atan2(-pivot.x, -pivot.y) * 180 / .pi
        return -toCentre - atPivot
    }

    static func restAngle(pivot: (x: Double, y: Double), length: Double) -> Double {
        angle(toRadius: restRadius, pivot: pivot, length: length)
    }

    /// The needle's place (record radii from the centre) for an arm turned `angle` degrees from rest.
    static func needle(angleFromRest: Double, pivot: (x: Double, y: Double) = armPivot, length: Double = armLength) -> (x: Double, y: Double) {
        let direction = (restAngle(pivot: pivot, length: length) + angleFromRest) * .pi / 180
        // Clockwise from straight down: x = -sin, y = cos.
        return (pivot.x - sin(direction) * length, pivot.y + cos(direction) * length)
    }
}
