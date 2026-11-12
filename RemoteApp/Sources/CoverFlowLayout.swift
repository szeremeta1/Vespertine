//
// Vespertine Remote: where each cover sits in Cover Flow, and how a tilt of the device shifts the view. Numbers only,
// so the tests can check them.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import CoreGraphics
import Foundation

/// A tilt of the device from how it was being held: -1…1 left to right and top to bottom.
nonisolated struct Tilt: Equatable, Sendable {
    var x: Double
    var y: Double
    static let zero = Tilt(x: 0, y: 0)
}

nonisolated struct CoverFlowLayout: Equatable, Sendable {
    /// The side of the front cover, in points.
    var coverSide: CGFloat
    /// Covers lie flat side by side (Reduce Motion): no turning in space.
    var flat = false

    /// How one cover is drawn.
    struct Pose: Equatable, Sendable {
        /// Sideways from the middle, in points.
        var x: CGFloat
        /// Turned about its vertical axis, in degrees (positive: its right edge away from the viewer).
        var angle: Double
        var scale: CGFloat
        /// Which covers are in front (higher: nearer).
        var z: Double
        var opacity: Double
        /// 0 at the front, 1 for every cover in the stacks.
        var depth: Double
    }

    /// How far to the side a cover's first step from the front takes it, and each step after that.
    var firstStep: CGFloat { coverSide * (flat ? 1.06 : 0.62) }
    var nextStep: CGFloat { coverSide * (flat ? 1.06 : 0.2) }
    static let sideAngle = 64.0
    /// How many covers each side are drawn.
    static let reach = 6

    /// The pose of the cover `offset` places from the one in front (fractions while the row moves), under `tilt`.
    func pose(offset: Double, tilt: Tilt = .zero) -> Pose {
        let distance = abs(offset)
        let side: Double = offset < 0 ? -1 : 1
        let turn = min(distance, 1)
        var x = side * (turn * firstStep + max(distance - 1, 0) * nextStep)
        var angle = flat ? 0 : side * turn * Self.sideAngle
        let scale = flat ? 1 - 0.12 * turn : 1 - 0.16 * turn
        let fade = max(0, min(1, Double(Self.reach) - distance))
        if !flat {
            // Looking round the stack: the further back a cover, the more it slides against the tilt, and every
            // cover turns a little towards the viewer's new side.
            x -= tilt.x * (6 + turn * 18 + max(distance - 1, 0) * 5)
            angle += tilt.x * Self.tiltAngle * (0.35 + 0.65 * turn)
        }
        return Pose(x: x, angle: angle, scale: scale, z: -distance, opacity: fade * (1 - 0.1 * min(distance, 3)), depth: turn)
    }

    static let tiltAngle = 9.0

    /// The whole row leans with the device's top-to-bottom tilt, in degrees about the horizontal axis.
    func stagePitch(tilt: Tilt) -> Double {
        flat ? 0 : -tilt.y * 5
    }

    /// The cover indexes worth drawing around `position` in a library of `count`.
    func visible(around position: Double, count: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let lower = max(0, Int(position.rounded(.down)) - Self.reach)
        let upper = min(count - 1, Int(position.rounded(.up)) + Self.reach)
        return lower..<(max(lower, upper) + 1)
    }

    /// How many covers a drag of `translation` points moves the row (dragging left moves on).
    func travel(translation: CGFloat) -> Double {
        -Double(translation / (coverSide * 0.5))
    }

    /// Where the row comes to rest: the nearest cover to where the drag was heading, inside the library.
    func rest(from start: Double, translation: CGFloat, predicted: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        // A flick carries on, but not across the whole library.
        let carried = translation + max(-coverSide * 3, min(coverSide * 3, predicted - translation))
        let target = (start + travel(translation: carried)).rounded()
        return Int(max(0, min(Double(count - 1), target)))
    }

    /// A dragged position, with resistance past either end.
    func dragged(from start: Double, translation: CGFloat, count: Int) -> Double {
        let raw = start + travel(translation: translation)
        let last = Double(max(count - 1, 0))
        if raw < 0 { return raw / 3 }
        if raw > last { return last + (raw - last) / 3 }
        return raw
    }
}

/// Turns gravity readings into a tilt from the way the device is being held. Holding it at a new angle becomes the
/// new "level" after a few seconds, so the picture doesn't stay skewed.
nonisolated struct TiltFilter: Sendable {
    /// Seconds for the resting angle to follow the device.
    var settle = 2.5
    /// How much lean (in g) gives a full tilt.
    var range = 0.35
    /// Seconds of smoothing on the result.
    var smoothing = 0.08

    private var baseline: (x: Double, y: Double)?
    private(set) var tilt = Tilt.zero

    enum Orientation: Sendable { case portrait, portraitUpsideDown, landscapeLeft, landscapeRight }

    /// Gravity across the screen as the user sees it: x to their right, y towards the bottom edge.
    static func screenGravity(x: Double, y: Double, orientation: Orientation) -> (x: Double, y: Double) {
        switch orientation {
        case .portrait: (x, -y)
        case .portraitUpsideDown: (-x, y)
        // Interface landscapeRight: the device's right edge is at the bottom.
        case .landscapeRight: (-y, -x)
        case .landscapeLeft: (y, x)
        }
    }

    /// Feeds one reading (`dt` seconds after the last) and returns the tilt.
    mutating func update(gravityX: Double, gravityY: Double, orientation: Orientation, dt: Double) -> Tilt {
        let g = Self.screenGravity(x: gravityX, y: gravityY, orientation: orientation)
        guard var base = baseline, dt > 0, dt < 1 else {
            baseline = g
            tilt = .zero
            return tilt
        }
        let follow = 1 - exp(-dt / settle)
        base.x += (g.x - base.x) * follow
        base.y += (g.y - base.y) * follow
        baseline = base
        let target = Tilt(x: max(-1, min(1, (g.x - base.x) / range)), y: max(-1, min(1, (g.y - base.y) / range)))
        let ease = 1 - exp(-dt / smoothing)
        tilt = Tilt(x: tilt.x + (target.x - tilt.x) * ease, y: tilt.y + (target.y - tilt.y) * ease)
        return tilt
    }

    mutating func reset() {
        baseline = nil
        tilt = .zero
    }
}
