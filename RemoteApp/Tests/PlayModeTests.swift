//
// Vespertine Remote: the Mac / This iPhone switch says who plays and can always be changed back; and the slider for this
// device's volume stays under the finger, sets the system's volume, and lets go when iOS reports the level.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineRemote

@MainActor
@Suite struct PlayModeSwitching {
    @Test func aShareHasNoSwitch() {
        #expect(PlayMode.offersSwitch(share: false))
        #expect(!PlayMode.offersSwitch(share: true))
    }

    @Test func theModeIsWhoThePlayerIs() {
        #expect(PlayMode.current(playsHere: true) == .device)
        #expect(PlayMode.current(playsHere: false) == .mac)
    }

    @Test func theMacCanAlwaysBeChosenAndThisDeviceOnlyWhenTheMacCanSendSongs() {
        #expect(PlayMode.canChoose(.mac, canPlayHere: false))
        #expect(PlayMode.canChoose(.mac, canPlayHere: true))
        #expect(PlayMode.canChoose(.device, canPlayHere: true))
        #expect(!PlayMode.canChoose(.device, canPlayHere: false))
    }

    @Test func eachModeHasItsOwnPictureAndWords() {
        #expect(PlayMode.device.symbol(pad: true) == "ipad")
        #expect(PlayMode.device.symbol(pad: false) == "iphone")
        #expect(PlayMode.mac.symbol(pad: false) == PlayMode.mac.symbol(pad: true))
        let remote = PlayModeSwitch.explanation(.mac, mac: "Studio Mac mini")
        let here = PlayModeSwitch.explanation(.device, mac: "Studio Mac mini")
        #expect(remote != here)
        #expect(remote.contains("Studio Mac mini") && here.contains("Studio Mac mini"))
    }
}

@MainActor
@Suite struct OutputScreen {
    @Test func eachSidesOutputsShowOnlyWhileThatSidePlays() {
        // The Mac plays: its outputs, and nothing of this device's.
        #expect(OutputLayout.showsMacOutputs(playsHere: false, share: false))
        #expect(!OutputLayout.showsThisDevice(playsHere: false, share: false))
        // This device plays a Mac's songs: its own output, and none of the Mac's.
        #expect(OutputLayout.showsThisDevice(playsHere: true, share: false))
        #expect(!OutputLayout.showsMacOutputs(playsHere: true, share: false))
    }

    @Test func aShareOrFolderOnlyEverShowsThisDevice() {
        for playsHere in [true, false] {
            #expect(OutputLayout.showsThisDevice(playsHere: playsHere, share: true))
            #expect(!OutputLayout.showsMacOutputs(playsHere: playsHere, share: true))
        }
    }
}

@MainActor
@Suite struct DeviceVolumeSlider {
    @Test func theSliderShowsWhatIOSReportsUntilItIsDragged() {
        let volume = DeviceVolume()
        #expect(volume.shown(reported: 0.4) == 0.4)
        #expect(volume.shown(reported: nil) == 0)
        volume.drag(to: 0.7)
        #expect(volume.shown(reported: 0.4) == 0.7)
    }

    @Test func aLevelIOSNeverReportedIsNotShownAsZero() {
        let volume = DeviceVolume()
        #expect(volume.label(reported: nil) == "—")
        #expect(volume.label(reported: 0.3) == DeviceVolume.percent(0.3))
        volume.drag(to: 0.7)
        #expect(volume.label(reported: nil) == DeviceVolume.percent(0.7))
    }

    @Test func aDragSetsTheSystemVolumeAtEveryStep() {
        let volume = DeviceVolume()
        var set: [Double] = []
        volume.apply = { set.append($0) }
        volume.drag(to: 0.25)
        volume.drag(to: 0.5)
        volume.drag(to: 1.4)
        volume.drag(to: -.infinity)
        #expect(set == [0.25, 0.5, 1, 0])
    }

    @Test func reportsDuringADragAreOlderThanTheFinger() {
        let volume = DeviceVolume()
        volume.drag(to: 0.8)
        volume.reported(0.8)
        #expect(volume.held == 0.8)
    }

    @Test func theSliderLetsGoWhenIOSReportsTheLevelAskedFor() {
        let volume = DeviceVolume()
        volume.settle = .seconds(600)
        volume.drag(to: 0.8)
        volume.end()
        volume.reported(0.3)
        #expect(volume.held == 0.8)
        volume.reported(0.81)
        #expect(volume.held == nil)
        #expect(volume.shown(reported: 0.81) == 0.81)
    }

    @Test func theSliderLetsGoAfterAMomentWhenIOSNeverReportsTheLevel() async throws {
        let volume = DeviceVolume()
        volume.settle = .milliseconds(1)
        volume.drag(to: 0.6)
        volume.end()
        for _ in 0..<400 where volume.held != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(volume.held == nil)
    }

    @Test func aNewDragTakesOverFromAnEndedOne() async throws {
        let volume = DeviceVolume()
        volume.settle = .milliseconds(20)
        volume.drag(to: 0.6)
        volume.end()
        volume.drag(to: 0.2)
        try await Task.sleep(for: .milliseconds(80))
        #expect(volume.held == 0.2)
    }

    @Test func theLevelIsSaidAsAWholePercentage() {
        #expect(DeviceVolume.percent(0.624).filter(\.isNumber) == "62")
        #expect(DeviceVolume.percent(7).filter(\.isNumber) == "100")
        #expect(DeviceVolume.percent(.nan).filter(\.isNumber) == "0")
    }
}

@MainActor
@Suite struct NowPlayingOnAShortScreen {
    @Test func aShortUprightScreenIsTightAndATallOrWideOneIsNot() {
        #expect(RemoteLayout.playerIsTight(height: 520, columns: false))
        #expect(!RemoteLayout.playerIsTight(height: 700, columns: false))
        #expect(!RemoteLayout.playerIsTight(height: 320, columns: true))
    }

    @Test func aTightScreenGivesTheCoverAndTheGapsLessRoom() {
        let tight = RemoteLayout.coverSide(width: 320, height: 500, columns: false, tight: true)
        let roomy = RemoteLayout.coverSide(width: 320, height: 500, columns: false)
        #expect(tight < roomy)
        #expect(tight >= 120)
        #expect(RemoteLayout.playerSpacing(tight: true).parts < RemoteLayout.playerSpacing(tight: false).parts)
        #expect(RemoteLayout.playerSpacing(tight: true).controls < RemoteLayout.playerSpacing(tight: false).controls)
        #expect(RemoteLayout.playModeSwitchHeight(tight: true) < RemoteLayout.playModeSwitchHeight(tight: false))
    }
}
