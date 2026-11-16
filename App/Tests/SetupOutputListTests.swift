import CoreGraphics
import Testing
@testable import Vespertine

/// The Output step's device list grows with the window and says when there is more below: with six outputs in a box
/// that showed four, a DAC at the end of the list was out of sight with nothing to hint at it.
@Suite("Setup: the list of outputs")
struct SetupOutputListTests {
    @Test("At the smallest window the list is at least as tall as it was")
    func neverSmallerThanBefore() {
        // The setup window's minimum is 680 high; the page between the progress bar and the buttons gets about 540 of it.
        #expect(SetupOutputList.maxHeight(pageHeight: 540, dopCard: false) >= 300)
        #expect(SetupOutputList.maxHeight(pageHeight: 540, dopCard: true) >= 210)
        // A page smaller than any window gives still falls back to those.
        #expect(SetupOutputList.maxHeight(pageHeight: 0, dopCard: false) == 300)
        #expect(SetupOutputList.maxHeight(pageHeight: 0, dopCard: true) == 210)
    }

    @Test("A taller window gives the list the extra room, less the DoP card while that is shown")
    func growsWithTheWindow() {
        let small = SetupOutputList.maxHeight(pageHeight: 540, dopCard: false)
        let tall = SetupOutputList.maxHeight(pageHeight: 740, dopCard: false)
        #expect(tall == small + 200)
        #expect(SetupOutputList.maxHeight(pageHeight: 740, dopCard: true) == tall - SetupOutputList.dopCard)
        #expect(SetupOutputList.maxHeight(pageHeight: 2000, dopCard: false) > 1500)
    }

    @Test("The window setup opens in (1440 x 877) shows System Default and five devices without scrolling")
    func sixRowsFitTheOpeningWindow() {
        // 877 less the buttons (88) and the progress bar (about 50).
        let height = SetupOutputList.maxHeight(pageHeight: 739, dopCard: false)
        #expect(!SetupOutputList.overflows(rows: 6, maxHeight: height))
        #expect(SetupOutputList.overflows(rows: 12, maxHeight: height))
    }

    @Test("More rows than fit are said to overflow, so the scroll bar and the fade show; rows that fit are not")
    func overflow() {
        #expect(SetupOutputList.contentHeight(rows: 0) == 0)
        #expect(SetupOutputList.contentHeight(rows: 1) == 76)
        #expect(SetupOutputList.contentHeight(rows: 4) == 4 * 64 + 3 * 10 + 12)
        #expect(!SetupOutputList.overflows(rows: 4, maxHeight: 300))
        #expect(SetupOutputList.overflows(rows: 5, maxHeight: 300))
        #expect(SetupOutputList.overflows(rows: 3, maxHeight: 210))
        #expect(!SetupOutputList.overflows(rows: 2, maxHeight: 210))
    }

    @Test("Each row has its own place to scroll to; System Default is not mistaken for a device")
    func rowIDs() {
        #expect(SetupOutputList.rowID(nil) == "system-default")
        #expect(SetupOutputList.rowID("BlackHole2ch_UID") == "device:BlackHole2ch_UID")
        #expect(SetupOutputList.rowID("system-default") != SetupOutputList.rowID(nil))
        #expect(SetupOutputList.rowID("a") != SetupOutputList.rowID("b"))
    }
}
