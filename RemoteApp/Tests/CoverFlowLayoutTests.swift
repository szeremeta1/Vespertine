//
// Vespertine Remote: Cover Flow's geometry and the tilt that shifts it.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import CoreGraphics
import Testing
@testable import VespertineRemote

@Suite struct CoverFlowGeometry {
    let layout = CoverFlowLayout(coverSide: 200)

    @Test func theFrontCoverFacesTheViewer() {
        let pose = layout.pose(offset: 0)
        #expect(pose.x == 0)
        #expect(pose.angle == 0)
        #expect(pose.scale == 1)
        #expect(pose.opacity == 1)
        #expect(pose.depth == 0)
    }

    @Test func theSidesMirrorEachOtherAndTurnAway() {
        let left = layout.pose(offset: -2), right = layout.pose(offset: 2)
        #expect(left.x == -right.x)
        #expect(left.angle == -right.angle)
        #expect(right.angle == CoverFlowLayout.sideAngle)
        #expect(right.x > 0)
        #expect(left.scale == right.scale)
        #expect(right.scale < 1)
    }

    @Test func coversFurtherAwayAreBehindAndFurtherOut() {
        var last = layout.pose(offset: 0)
        for step in 1...8 {
            let pose = layout.pose(offset: Double(step) * 0.5)
            #expect(pose.x > last.x)
            #expect(pose.z < last.z)
            #expect(pose.opacity <= last.opacity)
            last = pose
        }
        // The stacks are packed tighter than the gap beside the front cover.
        #expect(layout.pose(offset: 3).x - layout.pose(offset: 2).x < layout.pose(offset: 1).x)
        #expect(layout.pose(offset: Double(CoverFlowLayout.reach)).opacity == 0)
    }

    @Test func aTiltSlidesTheStacksAndTurnsTheCovers() {
        let level = layout.pose(offset: 2), tilted = layout.pose(offset: 2, tilt: Tilt(x: 1, y: 0))
        #expect(tilted.x < level.x)
        #expect(tilted.angle > level.angle)
        // Deeper covers move more than the front one: that difference is the parallax.
        let front = layout.pose(offset: 0, tilt: Tilt(x: 1, y: 0))
        #expect(abs(tilted.x - level.x) > abs(front.x))
        #expect(front.angle != 0)
        #expect(layout.stagePitch(tilt: Tilt(x: 0, y: 1)) != 0)
        #expect(layout.pose(offset: 2, tilt: .zero) == level)
    }

    @Test func reduceMotionKeepsEverythingFlat() {
        let flat = CoverFlowLayout(coverSide: 200, flat: true)
        for offset in [-3.0, -1, -0.4, 0, 0.5, 1, 4] {
            let pose = flat.pose(offset: offset, tilt: Tilt(x: 1, y: -1))
            #expect(pose.angle == 0)
            #expect(pose == flat.pose(offset: offset))
        }
        #expect(flat.stagePitch(tilt: Tilt(x: 1, y: 1)) == 0)
        // Flat covers don't overlap.
        #expect(flat.pose(offset: 1).x >= 200)
    }

    @Test func onlyNearbyCoversAreDrawn() {
        #expect(layout.visible(around: 0, count: 0).isEmpty)
        #expect(layout.visible(around: 0, count: 3) == 0..<3)
        #expect(layout.visible(around: 50, count: 1000) == 44..<57)
        #expect(layout.visible(around: 50.5, count: 1000) == 44..<58)
        #expect(layout.visible(around: 999, count: 1000) == 993..<1000)
        // A position past the end (rubber-banding) still draws the last covers.
        #expect(layout.visible(around: 1000.4, count: 1000).contains(999))
    }

    @Test func dragsMoveAndComeToRestOnACover() {
        // Dragging left by half a cover moves on by one.
        #expect(layout.travel(translation: -100) == 1)
        #expect(layout.rest(from: 3, translation: -100, predicted: -100, count: 10) == 4)
        #expect(layout.rest(from: 3, translation: 30, predicted: 30, count: 10) == 3)
        // A flick carries on, but stays in the library.
        #expect(layout.rest(from: 3, translation: -100, predicted: -400, count: 10) == 7)
        #expect(layout.rest(from: 3, translation: -100, predicted: -90_000, count: 10) == 9)
        #expect(layout.rest(from: 1, translation: 100, predicted: 90_000, count: 10) == 0)
        #expect(layout.rest(from: 0, translation: -50, predicted: -50, count: 0) == 0)
        // Past either end the row resists.
        #expect(layout.dragged(from: 0, translation: 300, count: 10) == -1)
        #expect(layout.dragged(from: 9, translation: -300, count: 10) == 10)
        #expect(layout.dragged(from: 4, translation: -100, count: 10) == 5)
    }
}

@Suite struct TiltReadings {
    @Test func theFirstReadingIsLevel() {
        var filter = TiltFilter()
        #expect(filter.update(gravityX: 0.4, gravityY: -0.8, orientation: .portrait, dt: 0) == .zero)
    }

    @Test func leaningRightTiltsRightAndIsLimited() {
        var filter = TiltFilter()
        _ = filter.update(gravityX: 0, gravityY: -1, orientation: .portrait, dt: 0)
        var tilt = Tilt.zero
        for _ in 0..<30 { tilt = filter.update(gravityX: 0.2, gravityY: -1, orientation: .portrait, dt: 1.0 / 60) }
        #expect(tilt.x > 0.3)
        #expect(abs(tilt.y) < 0.01)
        for _ in 0..<30 { tilt = filter.update(gravityX: 5, gravityY: -1, orientation: .portrait, dt: 1.0 / 60) }
        #expect(tilt.x <= 1)
    }

    @Test func aNewWayOfHoldingBecomesLevel() {
        var filter = TiltFilter()
        _ = filter.update(gravityX: 0, gravityY: -1, orientation: .portrait, dt: 0)
        var tilt = Tilt.zero
        for _ in 0..<(60 * 30) { tilt = filter.update(gravityX: 0.25, gravityY: -0.9, orientation: .portrait, dt: 1.0 / 60) }
        #expect(abs(tilt.x) < 0.02)
        #expect(abs(tilt.y) < 0.02)
    }

    @Test func aGapInReadingsStartsAgain() {
        var filter = TiltFilter()
        _ = filter.update(gravityX: 0, gravityY: -1, orientation: .portrait, dt: 0)
        _ = filter.update(gravityX: 0.3, gravityY: -1, orientation: .portrait, dt: 1.0 / 60)
        #expect(filter.update(gravityX: 0.3, gravityY: -1, orientation: .portrait, dt: 5) == .zero)
    }

    @Test func landscapeSwapsTheAxes() {
        // Upright portrait: gravity pulls towards the bottom edge.
        #expect(TiltFilter.screenGravity(x: 0, y: -1, orientation: .portrait) == (0, 1))
        #expect(TiltFilter.screenGravity(x: 0, y: 1, orientation: .portraitUpsideDown) == (0, 1))
        // Landscape with the device's right edge down: gravity is along the device's +x, the screen's bottom.
        #expect(TiltFilter.screenGravity(x: -1, y: 0, orientation: .landscapeRight) == (0, 1))
        #expect(TiltFilter.screenGravity(x: 1, y: 0, orientation: .landscapeLeft) == (0, 1))
        // Leaning to the user's right shows as +x in every orientation.
        #expect(TiltFilter.screenGravity(x: 0.5, y: 0, orientation: .portrait).x == 0.5)
        #expect(TiltFilter.screenGravity(x: 0, y: -0.5, orientation: .landscapeRight).x == 0.5)
        #expect(TiltFilter.screenGravity(x: 0, y: 0.5, orientation: .landscapeLeft).x == 0.5)
    }
}
