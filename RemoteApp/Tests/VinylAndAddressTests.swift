//
// Vespertine Remote: the record's turning and tonearm, the address field, and the app's saved choices.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteClient
import VespertineRemoteProtocol
@testable import VespertineRemote

@Suite struct Vinyl {
    @Test func turnsAtThirtyThreeAndAThird() {
        #expect(VinylGeometry.rotation(position: 0) == 0)
        #expect(VinylGeometry.rotation(position: 0.9) == 180)
        // One turn takes 1.8 seconds.
        #expect(abs(VinylGeometry.rotation(position: 1.8)) < 1e-9)
        #expect(abs(VinylGeometry.rotation(position: 3600.45) - 90) < 1e-6)
        #expect(VinylGeometry.rotation(position: -4) == 0)
        #expect(VinylGeometry.rotation(position: .nan) == 0)
    }

    @Test func theNeedleCrossesFromTheEdgeToTheLabel() {
        #expect(VinylGeometry.needleRadius(progress: 0) == VinylGeometry.grooveOuter)
        #expect(abs(VinylGeometry.needleRadius(progress: 1) - VinylGeometry.grooveInner) < 1e-12)
        #expect(VinylGeometry.needleRadius(progress: 7) == VinylGeometry.needleRadius(progress: 1))
        #expect(VinylGeometry.needleRadius(progress: .nan) == VinylGeometry.grooveOuter)
        // It never reaches the label.
        #expect(VinylGeometry.grooveInner > VinylGeometry.labelShare)
    }

    @Test func theArmSwingsInwardAsTheSongPlays() {
        var last = 0.0
        for step in 0...10 {
            let angle = VinylGeometry.tonearmAngle(progress: Double(step) / 10)
            #expect(angle > last)
            last = angle
        }
        #expect(last < 45)
    }

    @Test func theNeedleLandsWhereTheGeometrySays() {
        for progress in [0.0, 0.25, 0.5, 1] {
            let needle = VinylGeometry.needle(angleFromRest: VinylGeometry.tonearmAngle(progress: progress))
            let radius = (needle.x * needle.x + needle.y * needle.y).squareRoot()
            #expect(abs(radius - VinylGeometry.needleRadius(progress: progress)) < 1e-9)
            // On the record's right-hand side, below the pivot.
            #expect(needle.x > 0)
            #expect(needle.y > VinylGeometry.armPivot.y)
        }
        // Parked, the needle is off the record.
        let parked = VinylGeometry.needle(angleFromRest: 0)
        #expect((parked.x * parked.x + parked.y * parked.y).squareRoot() > 1)
    }
}

@Suite struct AddressField {
    @Test func emptyMeansNoAddress() {
        #expect(AddressEntry("") == .empty)
        #expect(AddressEntry("  \n") == .empty)
        #expect(AddressEntry("").address == nil)
    }

    @Test func aTailscaleNameIsAccepted() {
        #expect(AddressEntry("studio-mac.tail1a2b3.ts.net") == .valid(RemoteAddress(host: "studio-mac.tail1a2b3.ts.net")))
        #expect(AddressEntry("100.101.102.103:52718").address?.port == 52718)
        #expect(AddressEntry("100.101.102.103:52718").address?.kind == .tailscale)
    }

    @Test func nonsenseIsRefused() {
        #expect(AddressEntry("my mac") == .invalid)
        #expect(AddressEntry("mac:port") == .invalid)
        #expect(AddressEntry("my mac").address == nil)
    }
}

@Suite @MainActor struct Choices {
    @Test func defaultsAreCalmAndChoicesAreKept() throws {
        let name = "vt-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.vinyl)
        #expect(settings.tiltParallax)
        #expect(settings.albumsLayout == .grid)
        settings.vinyl = true
        settings.tiltParallax = false
        settings.albumsLayout = .coverFlow
        let again = AppSettings(defaults: defaults)
        #expect(again.vinyl)
        #expect(!again.tiltParallax)
        #expect(again.albumsLayout == .coverFlow)
    }

    @Test func timesReadLikeAClock() {
        #expect(formatTime(0) == "0:00")
        #expect(formatTime(74.9) == "1:14")
        #expect(formatTime(3725) == "1:02:05")
        #expect(formatTime(-1) == "0:00")
        #expect(formatTime(.infinity) == "0:00")
    }
}

@Suite struct DemoNotice {
    @Test func theDemoBarIsHiddenOnlyInScreenshotRuns() {
        #expect(RemoteAppModel.showsDemoNotice(isDemo: true, screenshotRun: false))
        #expect(!RemoteAppModel.showsDemoNotice(isDemo: true, screenshotRun: true))
        #expect(!RemoteAppModel.showsDemoNotice(isDemo: false, screenshotRun: false))
    }
}

@Suite @MainActor struct ConvertingAndReach {
    @Test func convertingSaysHowFarAlongOnceTheMacKnows() {
        // DSD, WavPack and Vorbis are converted on the Mac first: Now Playing says so instead of only spinning.
        let unknown = NowPlayingView.converting(progress: nil)
        #expect(!unknown.isEmpty)
        #expect(!unknown.contains { $0.isNumber })
        #expect(NowPlayingView.converting(progress: 0) == unknown)
        #expect(NowPlayingView.converting(progress: 0.42).contains("42"))
        // Never past the end, whatever the Mac says.
        #expect(NowPlayingView.converting(progress: 3).contains("100"))
    }

    @Test func theRouteIsNamedAndKeptSongsSayTheyPlayFromHere() {
        let home = NowPlayingView.source(reach: .sameNetwork, connected: true, demo: false)
        let tailscale = NowPlayingView.source(reach: .tailscale, connected: true, demo: false)
        let kept = NowPlayingView.source(reach: nil, connected: false, demo: false)
        #expect(home != nil && tailscale != nil && kept != nil)
        #expect(Set([home, tailscale, kept]).count == 3)
        #expect(NowPlayingView.source(reach: .sameNetwork, connected: true, demo: true) == nil)
    }

    @Test func everyReasonForNotReachingTheMacHasItsOwnWordsAndNamesTheMac() {
        let all: [ReachTrouble] = [.offline, .notOnThisNetwork, .tailscaleOff, .notAnswering]
        let words = all.map { ConnectionBanner.words($0, mac: "Studio Mac") }
        #expect(Set(words).count == all.count)
        for text in words.dropFirst() { #expect(text.contains("Studio Mac")) }
    }
}
