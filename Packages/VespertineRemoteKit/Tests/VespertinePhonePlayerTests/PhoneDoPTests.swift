//
// Vespertine: DSD on a DAC plugged into the phone. Which DACs are sent DoP (only ones that passed the listening test, only
// while the output can carry the frames exactly), the test sound itself, and what the phone's player does with a song that
// arrives as DoP frames: the output is brought to their rate before a note is played, and when it can't be, or stops
// being right, the song is asked for again as PCM.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteProtocol
@testable import VespertinePhonePlayer

private func dac(rate: Double = 44_100, channels: Int = 2, uid: String? = "usb:fiio-k11") -> PhoneRoute {
    PhoneRoute(name: "K11", portType: "USBAudio", sampleRate: rate, channels: channels, spatial: false, uid: uid)
}

@Suite struct WhichDACsGetDoP {
    @Test func aDacGetsDoPOnlyAfterItAnsweredMusic() {
        var dacs = DoPDACs()
        #expect(dacs.ceiling(for: "a") == nil && dacs.answer(for: "a") == nil)
        dacs.record(.hiss, uid: "a", name: "A")
        #expect(dacs.ceiling(for: "a") == nil && dacs.answer(for: "a") == .hiss)
        dacs.record(.music, uid: "a", name: "A")
        #expect(dacs.ceiling(for: "a") == DoPDACs.highestCarrier)
        // One DAC's answer says nothing about another, and none at all about an output iOS doesn't identify.
        #expect(dacs.ceiling(for: "b") == nil && dacs.ceiling(for: nil) == nil)
        dacs.forget(uid: "a")
        #expect(dacs.ceiling(for: "a") == nil)
    }

    @Test func aRateTheDacDeclinedIsNotAskedForAgain() {
        var dacs = DoPDACs()
        dacs.record(.music, uid: "a", name: "A")
        dacs.declined(705_600, uid: "a")
        #expect(dacs.ceiling(for: "a") == 352_800)
        dacs.declined(352_800, uid: "a")
        #expect(dacs.ceiling(for: "a") == 176_400)
        // A higher rate declined later never raises it again.
        dacs.declined(705_600, uid: "a")
        #expect(dacs.ceiling(for: "a") == 176_400)
        // Declining the rate the test itself ran at takes the answer back: it has to be tested again.
        dacs.declined(176_400, uid: "a")
        #expect(dacs.ceiling(for: "a") == nil && dacs.answer(for: "a") == nil)
        // Testing again starts afresh.
        dacs.record(.music, uid: "a", name: "A")
        #expect(dacs.ceiling(for: "a") == DoPDACs.highestCarrier)
    }

    @Test func aDacThatAnsweredHissIsNotChangedByADecline() {
        var dacs = DoPDACs()
        dacs.record(.hiss, uid: "a", name: "A")
        dacs.declined(352_800, uid: "a")
        #expect(dacs.answer(for: "a") == .hiss)
    }

    @Test func theAnswersAreKeptBetweenLaunches() throws {
        let suite = "dop-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(DoPDACs.load(from: defaults) == DoPDACs())
        var dacs = DoPDACs()
        dacs.record(.music, uid: "a", name: "FiiO K11")
        dacs.record(.hiss, uid: "b", name: "Dongle")
        dacs.declined(705_600, uid: "a")
        dacs.save(to: defaults)
        #expect(DoPDACs.load(from: defaults) == dacs)
    }

    @Test func onlyAStereoUsbDacThatIosIdentifiesCanBeTested() {
        #expect(DoPGate.canTest(dac()))
        #expect(!DoPGate.canTest(nil))
        #expect(!DoPGate.canTest(dac(uid: nil)) && !DoPGate.canTest(dac(uid: "")))
        #expect(!DoPGate.canTest(dac(channels: 6)), "an interface running with six outputs")
        for port in ["Speaker", "BluetoothA2DPOutput", "AirPlay", "Headphones", "HDMI", "CarAudio"] {
            #expect(!DoPGate.canTest(PhoneRoute(name: "x", portType: port, sampleRate: 48_000, channels: 2, spatial: false, uid: "u")), "\(port)")
        }
    }

    @MainActor @Test func theVolumeIsSeenToMoveOnlyWhenIosReportsTwoLevelsOnTheSameOutput() {
        final class Session: OutputSession {
            var next = OutputReading()
            func read() -> OutputReading { next }
            func ask(rate: Double) {}
            func ask(channels: Int) {}
        }
        let session = Session()
        let watch = OutputWatch(session: session)
        session.next = OutputReading(route: dac(uid: "usb:zd3"), volume: 0.3)
        #expect(!watch.refresh(.start).volumeMoved)
        #expect(!watch.refresh(.heartbeat).volumeMoved, "the same level again says nothing")
        session.next.volume = 0.35
        #expect(watch.refresh(.volume).volumeMoved)
        #expect(watch.refresh(.heartbeat).volumeMoved, "and it stays said")
        // Another output starts unseen.
        session.next = OutputReading(route: dac(), volume: 0.35)
        #expect(!watch.refresh(.routeChange).volumeMoved)
    }

    @Test func doPNeedsATestedDacAndTheVolumeAtItsTop() {
        var dacs = DoPDACs()
        dacs.record(.music, uid: "usb:fiio-k11", name: "K11")
        #expect(DoPGate.ceiling(route: dac(), volume: 1, dacs: dacs) == DoPDACs.highestCarrier)
        #expect(DoPGate.ceiling(route: dac(), volume: 0.9, dacs: dacs) == nil, "below the top, iOS may be scaling the samples")
        #expect(DoPGate.ceiling(route: dac(), volume: nil, dacs: dacs) == nil, "an unknown volume is not assumed to be full")
        #expect(DoPGate.ceiling(route: dac(uid: "usb:other"), volume: 1, dacs: dacs) == nil, "another DAC")
        #expect(DoPGate.ceiling(route: dac(channels: 6), volume: 1, dacs: dacs) == nil)
        #expect(DoPGate.ceiling(route: nil, volume: 1, dacs: dacs) == nil)
        #expect(DoPGate.ceiling(route: dac(), volume: 1, dacs: DoPDACs()) == nil, "never tested")
        let speaker = PhoneRoute(name: "Speaker", portType: "Speaker", sampleRate: 48_000, channels: 2, spatial: false, uid: "usb:fiio-k11")
        #expect(DoPGate.ceiling(route: speaker, volume: 1, dacs: dacs) == nil)
    }

    // TestFlight AIPS3rYlDtQxr7x-IBSUOr0: "the test DoP button says volume must be at 100%, even when the DAC (my Fosi
    // ZD3) LITERALLY DOESN'T OFFER SOFTWARE VOLUME CONTROL".
    @Test func aDacThatPlayedTheChordBelowTheTopGetsDoPAtThatLevelWhateverIosCallsIt() {
        for level in [0.3, 0.0, nil] as [Double?] {
            var dacs = DoPDACs()
            var run = DoPTestRun(uid: "usb:zd3", name: "ZD3", volume: level)
            #expect(run.heard(.music, into: &dacs) == .next)
            let zd3 = dac(uid: "usb:zd3")
            // The chord is only heard if every frame arrived bit for bit: at this level iOS changes nothing.
            #expect(dacs.heardBelowTop(at: level, for: "usb:zd3"))
            #expect(DoPGate.ceiling(route: zd3, volume: level, dacs: dacs) == DoPDACs.highestCarrier, "\(String(describing: level))")
            #expect(DoPGate.reason(route: zd3, volume: level, dacs: dacs) == nil)
            #expect(DoPGate.ceiling(route: zd3, volume: 1, dacs: dacs) == DoPDACs.highestCarrier, "and at the top, as for any DAC")
            // Only that level is vouched for: another one may be scaled, so it is PCM there, and says why.
            let other: Double? = level == 0.3 ? 0.5 : 0.3
            #expect(DoPGate.ceiling(route: zd3, volume: other, dacs: dacs) == nil)
            #expect(DoPGate.reason(route: zd3, volume: other, dacs: dacs) == .volume)
            // And only this DAC.
            #expect(!dacs.heardBelowTop(at: level, for: "usb:fiio-k11"))
            #expect(DoPGate.ceiling(route: dac(), volume: level, dacs: dacs) == nil)
        }
    }

    @Test func aChordHeardAtTheTopSaysNothingAboutLowerLevels() {
        var dacs = DoPDACs()
        var run = DoPTestRun(uid: "usb:fiio-k11", name: "K11", volume: 1)
        _ = run.heard(.music, into: &dacs)
        #expect(dacs.entries["usb:fiio-k11"]?.level == nil)
        #expect(!dacs.heardBelowTop(at: 0.3, for: "usb:fiio-k11") && !dacs.heardBelowTop(at: nil, for: "usb:fiio-k11") && !dacs.heardBelowTop(at: 1, for: "usb:fiio-k11"))
        #expect(DoPGate.ceiling(route: dac(), volume: 0.3, dacs: dacs) == nil && DoPGate.ceiling(route: dac(), volume: nil, dacs: dacs) == nil)
        #expect(DoPGate.reason(route: dac(), volume: 0.3, dacs: dacs) == .volume)
    }

    @Test func whyDsdIsPlayedAsPCMIsSaidForEveryCase() {
        var dacs = DoPDACs()
        #expect(DoPGate.reason(route: nil, volume: 1, dacs: dacs) == .notADAC)
        #expect(DoPGate.reason(route: PhoneRoute(name: "AirPods", portType: "BluetoothA2DPOutput", sampleRate: 48_000, channels: 2, spatial: true, uid: "bt"), volume: 1, dacs: dacs) == .notADAC)
        #expect(DoPGate.reason(route: dac(), volume: 1, dacs: dacs) == .notTested)
        dacs.record(.hiss, uid: "usb:fiio-k11", name: "K11")
        #expect(DoPGate.reason(route: dac(), volume: 1, dacs: dacs) == .failedTest)
        var run = DoPTestRun(uid: "usb:fiio-k11", name: "K11")
        for result in [DoPDACs.CarrierResult.passed, .passed, .hiss, .hiss] { _ = run.finish(result, into: &dacs) }
        #expect(DoPGate.reason(route: dac(), volume: 1, dacs: dacs) == nil)
        #expect(DoPGate.reason(route: dac(), volume: 0.8, dacs: dacs) == .volume && DoPGate.reason(route: dac(), volume: nil, dacs: dacs) == .volume)
        // DSD64 goes as DoP; DSD128 needs a rate this DAC didn't pass at.
        #expect(DoPGate.reason(route: dac(), volume: 1, dacs: dacs, carrier: 176_400) == nil)
        #expect(DoPGate.reason(route: dac(), volume: 1, dacs: dacs, carrier: 352_800) == .rate)
        // It never disagrees with the ceiling.
        for volume in [1, 0.8, nil] as [Double?] {
            #expect((DoPGate.reason(route: dac(), volume: volume, dacs: dacs) == nil) == (DoPGate.ceiling(route: dac(), volume: volume, dacs: dacs) != nil))
        }
    }

    @Test func aSongsCarrierRateIsReadFromItsFormat() {
        #expect(DoPGate.carrier(format: "DSD64") == 176_400 && DoPGate.carrier(format: "DSD128") == 352_800 && DoPGate.carrier(format: "DSD256 · 5.1") == 705_600)
        #expect(DoPGate.carrier(format: "FLAC · 24/96") == nil && DoPGate.carrier(format: "") == nil)
        #expect(DoPGate.name(carrier: 384_000) == "DSD128" && DoPGate.name(carrier: 176_400) == "DSD64" && DoPGate.name(carrier: 192_000) == "DSD64")
    }

    @Test func whereTheVolumeIsSetIsSaidOnlyFromWhatWasSeen() {
        var dacs = DoPDACs()
        let zd3 = dac(uid: "usb:zd3")
        // Nothing seen: unknown. iOS has no API that says an output's volume is fixed, so it is never assumed.
        #expect(DoPGate.level(OutputState(route: zd3, volume: 0.3), dacs: dacs) == .unknown)
        #expect(DoPGate.level(OutputState(route: zd3, volume: nil), dacs: dacs) == .unknown)
        // The number moved while this was the output: the phone's buttons set it.
        #expect(DoPGate.level(OutputState(route: zd3, volume: 0.4, volumeMoved: true), dacs: dacs) == .phone)
        // The chord was heard at this level below the top: the DAC sets it.
        var run = DoPTestRun(uid: "usb:zd3", name: "ZD3", volume: 0.3)
        _ = run.heard(.music, into: &dacs)
        #expect(DoPGate.level(OutputState(route: zd3, volume: 0.3), dacs: dacs) == .dac)
        #expect(DoPGate.level(OutputState(route: zd3, volume: 0.6, volumeMoved: true), dacs: dacs) == .phone)
    }

    @Test func aSongOpenedAheadGetsDoPOnlyAtTheRateTheOutputAlreadyRunsAt() {
        #expect(DoPGate.aheadCeiling(ceiling: 768_000, outputRate: 176_400) == 176_400)
        #expect(DoPGate.aheadCeiling(ceiling: 768_000, outputRate: 352_800) == 352_800)
        #expect(DoPGate.aheadCeiling(ceiling: 768_000, outputRate: 44_100) == 44_100, "below every carrier rate: the Mac sends no DSD as DoP for it")
        #expect(DoPGate.aheadCeiling(ceiling: 768_000, outputRate: 0) == nil)
        #expect(DoPGate.aheadCeiling(ceiling: 176_400, outputRate: 352_800) == nil)
        #expect(DoPGate.aheadCeiling(ceiling: nil, outputRate: 176_400) == nil)
        #expect(DoPGate.aheadCeiling(ceiling: 768_000, outputRate: nil) == nil)
    }

    @Test func dsdRatesAreNamedAsEverywhereElse() {
        #expect(DoPGate.name(dsdRate: 2_822_400) == "DSD64" && DoPGate.name(dsdRate: 5_644_800) == "DSD128")
        #expect(DoPGate.name(dsdRate: 11_289_600) == "DSD256" && DoPGate.name(dsdRate: 3_072_000) == "DSD64")
    }
}

@Suite struct TheDoPTestAtEachCarrierRate {
    @Test func theChordIsPlayedAtTheCarriersOfDsd64AndDsd128InBothFamilies() {
        #expect(DoPDACs.testCarriers == [176_400, 192_000, 352_800, 384_000])
        #expect(DoPDACs.testCarriers.first == DoPDACs.testCarrier)
        // Sixteen DSD bits a frame: the DSD rate each carrier holds.
        #expect(DoPDACs.testCarriers.map { DoPGate.name(dsdRate: $0 * 16) } == ["DSD64", "DSD64", "DSD128", "DSD128"])
    }

    // TestFlight ACYG3aqcmGHtjCSJhP8P45c: "the options say music or hiss, but i actually didn't hear anything at all on
    // some of these runs". Silence had to be answered as hiss, which turned DoP off for the DAC.
    @Test func hearingNothingIsNeverKeptAsHiss() {
        var dacs = DoPDACs()
        var run = DoPTestRun(uid: "a", name: "A")
        // Once: the same rate is played again.
        #expect(run.heard(.nothing, into: &dacs) == .replay)
        #expect(run.carrier == 176_400 && dacs == DoPDACs())
        // Twice at the first rate: the run ends, and the DAC is as untested as it was.
        #expect(run.heard(.nothing, into: &dacs) == .ended(.silent))
        #expect(dacs == DoPDACs() && dacs.answer(for: "a") == nil && run.carrier == nil)
        // A DAC that had passed keeps what it had.
        dacs.record(.music, uid: "a", name: "A")
        let before = dacs
        var again = DoPTestRun(uid: "a", name: "A")
        _ = again.heard(.nothing, into: &dacs)
        #expect(again.heard(.nothing, into: &dacs) == .ended(.silent))
        #expect(dacs == before && dacs.ceiling(for: "a") == DoPDACs.highestCarrier)
    }

    @Test func playAgainPlaysTheSameRateAndKeepsNothingHoweverOftenItIsAsked() {
        var dacs = DoPDACs()
        var run = DoPTestRun(uid: "a", name: "A")
        for _ in 0..<5 { #expect(run.heard(.again, into: &dacs) == .replay) }
        #expect(run.carrier == 176_400 && dacs == DoPDACs())
        #expect(run.heard(.music, into: &dacs) == .next)
        #expect(dacs.answer(for: "a") == .music)
    }

    @Test func nothingThenMusicIsMusic() {
        var dacs = DoPDACs()
        var run = DoPTestRun(uid: "a", name: "A")
        #expect(run.heard(.nothing, into: &dacs) == .replay)
        #expect(run.heard(.music, into: &dacs) == .next)
        #expect(dacs.passed(for: "a") == [176_400])
        // The count starts again at each rate: one "nothing" at the next rate plays it again.
        #expect(run.heard(.nothing, into: &dacs) == .replay && run.carrier == 192_000)
    }

    @Test func noSoundAtALaterRateIsKeptAsNoSoundAndTheRunGoesOn() {
        var dacs = DoPDACs()
        var run = DoPTestRun(uid: "a", name: "A")
        #expect(run.heard(.music, into: &dacs) == .next)
        #expect(run.heard(.nothing, into: &dacs) == .replay)
        #expect(run.heard(.nothing, into: &dacs) == .next)
        #expect(run.carrier == 352_800)
        #expect(run.heard(.music, into: &dacs) == .next)
        #expect(run.heard(.noise, into: &dacs) == .ended(.on))
        #expect(dacs.results(for: "a").map(\.result) == [.passed, .silent, .passed, .hiss])
        #expect(dacs.silent(for: "a") == [192_000] && dacs.answer(for: "a") == .music)
        // Not heard at 192: nothing is sent as DoP at or above it until it is, as for any rate that didn't pass.
        #expect(dacs.ceiling(for: "a") == 176_400)
    }

    @Test func musicAndNoiseAnswerAsMusicAndHissAlwaysDid() {
        var dacs = DoPDACs()
        var run = DoPTestRun(uid: "a", name: "A")
        #expect(run.heard(.noise, into: &dacs) == .ended(.off))
        #expect(dacs.answer(for: "a") == .hiss && dacs.ceiling(for: "a") == nil)
        var again = DoPTestRun(uid: "a", name: "A")
        for _ in 0..<3 { #expect(again.heard(.music, into: &dacs) == .next) }
        #expect(again.heard(.music, into: &dacs) == .ended(.on))
        #expect(dacs.passed(for: "a") == DoPDACs.testCarriers)
    }

    @Test func noiseWithTheVolumeBelowTheTopProvesNothingAndIsNotKept() {
        // iOS scaling the samples makes noise of DoP on a DAC that decodes it perfectly well.
        for level in [0.3, nil] as [Double?] {
            var dacs = DoPDACs()
            var run = DoPTestRun(uid: "a", name: "A", volume: level)
            #expect(run.heard(.noise, into: &dacs) == .ended(.inconclusive))
            #expect(dacs == DoPDACs() && run.carrier == nil)
        }
        // Once the chord was heard at that level, noise at a later rate is that rate's result.
        var dacs = DoPDACs()
        var run = DoPTestRun(uid: "a", name: "A", volume: 0.3)
        #expect(run.heard(.music, into: &dacs) == .next)
        #expect(run.heard(.noise, into: &dacs) == .next)
        #expect(dacs.results(for: "a").map(\.result) == [.passed, .hiss])
    }

    @Test func aRunCountsOnlyWhileTheOutputAndTheVolumeStayAsTheyWere() {
        let zd3 = dac(rate: 176_400, uid: "usb:zd3")
        let low = DoPTestRun(uid: "usb:zd3", name: "ZD3", volume: 0.3)
        #expect(low.holds(on: OutputState(route: zd3, volume: 0.3)))
        #expect(!low.holds(on: OutputState(route: zd3, volume: 0.35)), "the volume moved")
        #expect(!low.holds(on: OutputState(route: zd3, volume: nil)))
        #expect(!low.holds(on: OutputState(route: dac(rate: 176_400), volume: 0.3)), "another DAC")
        #expect(!low.holds(on: OutputState(route: dac(rate: 176_400, channels: 6, uid: "usb:zd3"), volume: 0.3)))
        #expect(!low.holds(on: OutputState(route: nil, volume: 0.3)))
        let unknown = DoPTestRun(uid: "usb:zd3", name: "ZD3", volume: nil)
        #expect(unknown.holds(on: OutputState(route: zd3, volume: nil)) && !unknown.holds(on: OutputState(route: zd3, volume: 1)))
        let top = DoPTestRun(uid: "usb:zd3", name: "ZD3", volume: 1)
        #expect(top.holds(on: OutputState(route: zd3, volume: 0.999)) && !top.holds(on: OutputState(route: zd3, volume: 0.9)))
    }

    @Test func theLevelAChordWasHeardAtIsKeptBetweenLaunches() throws {
        let suite = "dop-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var dacs = DoPDACs()
        var run = DoPTestRun(uid: "a", name: "ZD3", volume: 0.3)
        _ = run.heard(.music, into: &dacs)
        _ = run.heard(.nothing, into: &dacs)
        _ = run.heard(.nothing, into: &dacs)
        dacs.save(to: defaults)
        let back = DoPDACs.load(from: defaults)
        #expect(back == dacs && back.heardBelowTop(at: 0.3, for: "a") && back.silent(for: "a") == [192_000])
        // What a build before this one wrote still reads, with no level.
        let old = #"{"entries":{"a":{"answer":"music","name":"K11","carriers":{"176400":"passed"}}}}"#
        defaults.set(Data(old.utf8), forKey: DoPDACs.defaultsKey)
        let read = DoPDACs.load(from: defaults)
        #expect(read.answer(for: "a") == .music && read.entries["a"]?.level == nil)
    }

    @Test func aRunPlaysEveryRateAndKeepsHowEachWent() {
        var dacs = DoPDACs()
        var run = DoPTestRun(uid: "a", name: "A")
        #expect(run.carrier == 176_400 && run.isFirst)
        #expect(run.finish(.passed, into: &dacs))
        // Music at the first rate turns DoP on there and then, whatever happens to the rest of the run.
        #expect(dacs.answer(for: "a") == .music && dacs.passed(for: "a") == [176_400])
        #expect(run.carrier == 192_000 && !run.isFirst)
        #expect(run.finish(.declined, into: &dacs))
        #expect(run.carrier == 352_800)
        #expect(run.finish(.passed, into: &dacs))
        #expect(run.carrier == 384_000)
        #expect(!run.finish(.hiss, into: &dacs), "the last rate ends the run")
        #expect(run.carrier == nil)
        #expect(dacs.results(for: "a").map(\.carrier) == DoPDACs.testCarriers)
        #expect(dacs.results(for: "a").map(\.result) == [.passed, .declined, .passed, .hiss])
        #expect(dacs.passed(for: "a") == [176_400, 352_800])
        #expect(dacs.passed(at: 352_800, for: "a") && !dacs.passed(at: 192_000, for: "a") && !dacs.passed(at: 96_000, for: "a"))
        // A run that is over takes nothing more.
        #expect(!run.finish(.passed, into: &dacs))
        #expect(dacs.results(for: "a").map(\.result) == [.passed, .declined, .passed, .hiss])
    }

    @Test func hissAtTheFirstRateEndsTheRunWithDoPOff() {
        var dacs = DoPDACs()
        var run = DoPTestRun(uid: "a", name: "A")
        #expect(!run.finish(.hiss, into: &dacs))
        #expect(run.carrier == nil)
        #expect(dacs.answer(for: "a") == .hiss && dacs.ceiling(for: "a") == nil)
        #expect(dacs.results(for: "a").map(\.result) == [.hiss] && dacs.passed(for: "a").isEmpty)
    }

    @Test func aFirstRateTheDacWouldNotRunAtSavesNothing() {
        var dacs = DoPDACs()
        var run = DoPTestRun(uid: "a", name: "A")
        #expect(!run.finish(.declined, into: &dacs))
        #expect(dacs == DoPDACs())
        // And an answer from an earlier run is left as it was.
        dacs.record(.music, uid: "a", name: "A")
        let before = dacs
        var again = DoPTestRun(uid: "a", name: "A")
        #expect(!again.finish(.declined, into: &dacs))
        #expect(dacs == before)
    }

    @Test func oneDacsResultsSayNothingAboutAnother() {
        var dacs = DoPDACs()
        var run = DoPTestRun(uid: "a", name: "A")
        while run.finish(.passed, into: &dacs) {}
        #expect(dacs.passed(for: "a") == DoPDACs.testCarriers)
        #expect(dacs.results(for: "b").isEmpty && dacs.results(for: nil).isEmpty)
        #expect(!dacs.passed(at: 176_400, for: "b") && !dacs.passed(at: 176_400, for: nil))
    }

    @Test func aRateAboveTheFirstIsKeptOnlyForADacThatPassedTheFirst() {
        var dacs = DoPDACs()
        dacs.record(.passed, carrier: 352_800, uid: "a")
        #expect(dacs == DoPDACs(), "never tested")
        dacs.record(.hiss, uid: "a", name: "A")
        dacs.record(.passed, carrier: 352_800, uid: "a")
        #expect(dacs.results(for: "a").map(\.result) == [.hiss])
        dacs.record(.music, uid: "a", name: "A")
        // The first rate's result is its answer: it can't be overwritten as a later rate.
        dacs.record(.hiss, carrier: 176_400, uid: "a")
        #expect(dacs.passed(for: "a") == [176_400])
    }

    @Test func testingAgainStartsTheResultsAfresh() {
        var dacs = DoPDACs()
        var run = DoPTestRun(uid: "a", name: "A")
        while run.finish(.passed, into: &dacs) {}
        var again = DoPTestRun(uid: "a", name: "A")
        #expect(again.finish(.passed, into: &dacs))
        #expect(dacs.passed(for: "a") == [176_400], "the rates not played again yet are not carried over")
    }

    @Test func noDsdIsSentAsDoPAtOrAboveARateTheTestDidNotPassAt() {
        func ceiling(_ results: [DoPDACs.CarrierResult]) -> Double? {
            var dacs = DoPDACs()
            var run = DoPTestRun(uid: "a", name: "A")
            for result in results { _ = run.finish(result, into: &dacs) }
            return dacs.ceiling(for: "a")
        }
        #expect(ceiling([.passed, .passed, .passed, .passed]) == DoPDACs.highestCarrier)
        #expect(ceiling([.passed]) == DoPDACs.highestCarrier, "rates not played yet are asked for as before")
        #expect(ceiling([.passed, .passed, .passed, .hiss]) == 352_800)
        #expect(ceiling([.passed, .passed, .declined, .passed]) == 192_000)
        #expect(ceiling([.passed, .passed, .hiss, .hiss]) == 192_000)
        #expect(ceiling([.passed, .hiss, .passed, .passed]) == 176_400)
        #expect(ceiling([.hiss]) == nil)
    }

    @Test func aRateDeclinedWhileASongPlayedIsNoLongerSaidToHavePassed() {
        var dacs = DoPDACs()
        var run = DoPTestRun(uid: "a", name: "A")
        while run.finish(.passed, into: &dacs) {}
        dacs.declined(352_800, uid: "a")
        #expect(dacs.results(for: "a").map(\.result) == [.passed, .passed, .declined, .passed])
        #expect(dacs.ceiling(for: "a") == 176_400)
        #expect(!dacs.passed(at: 352_800, for: "a"))
        // A rate the test never played gets no result from a decline.
        dacs.declined(705_600, uid: "a")
        #expect(dacs.results(for: "a").count == 4)
    }

    @Test func theResultsAreKeptBetweenLaunchesAndAnAnswerFromBeforeStillReads() throws {
        let suite = "dop-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var dacs = DoPDACs()
        var run = DoPTestRun(uid: "a", name: "FiiO K11")
        for result in [DoPDACs.CarrierResult.passed, .passed, .declined, .hiss] { _ = run.finish(result, into: &dacs) }
        dacs.save(to: defaults)
        let back = DoPDACs.load(from: defaults)
        #expect(back == dacs)
        #expect(back.results(for: "a").map(\.result) == [.passed, .passed, .declined, .hiss])

        // What a version that played one rate only wrote: music means that rate passed, and says nothing of the others.
        let old = Data(#"{"entries":{"a":{"answer":"music","name":"K11"},"b":{"answer":"hiss","name":"Dongle"},"c":{"answer":"music","name":"C","ceiling":176400}}}"#.utf8)
        let read = try JSONDecoder().decode(DoPDACs.self, from: old)
        #expect(read.passed(for: "a") == [176_400] && read.ceiling(for: "a") == DoPDACs.highestCarrier)
        #expect(read.results(for: "b").map(\.result) == [.hiss] && read.ceiling(for: "b") == nil)
        #expect(read.ceiling(for: "c") == 176_400)
    }
}

/// What is said about a song's own file on its way to a DAC, and everything that takes the words back.
@Suite struct WhenTheOriginalFileIsSaidToReachTheDacUntouched {
    private func stream(rate: Double = 192_000, bits: Int? = 24, channels: Int = 2, kind: StreamKind = .original, lossless: Bool = true, dsd: Double? = nil) -> StreamDescriptor {
        StreamDescriptor(stream: 1, kind: kind, byteSize: 10,
                         format: StreamFormat(codec: "FLAC", container: "flac", sampleRate: rate, bitDepth: bits, channels: channels, channelLabels: nil, lossless: lossless),
                         frames: 10, tag: "t", chunkSize: 1, dsdRate: dsd)
    }
    /// The song's own lossless file on a DAC at the song's rate with the volume at its top.
    private func playing(_ stream: StreamDescriptor? = nil, on route: PhoneRoute? = dac(rate: 192_000), volume: Double? = 1) -> PhoneSignal {
        var signal = PhoneSignal(stream: stream ?? self.stream(), route: route)
        signal.volume = volume
        return signal
    }

    @Test func theFileItselfOnADacAtItsOwnRateAndFullVolumeIsUntouched() {
        #expect(playing().untouched)
        #expect(playing(stream(rate: 44_100, bits: 16), on: dac(rate: 44_100)).untouched)
    }

    @Test func aVolumeBelowTheTopTakesItBack() {
        #expect(!playing(volume: 0.99).untouched)
        #expect(!playing(volume: 0.5).untouched)
        #expect(!playing(volume: nil).untouched, "an unknown volume is not assumed to be full")
    }

    @Test func aRateIosResamplesToTakesItBack() {
        #expect(!playing(on: dac(rate: 96_000)).untouched)
        #expect(!playing(on: dac(rate: 0)).untouched, "an unknown rate is not assumed to be the song's")
        #expect(!playing(on: nil).untouched)
    }

    @Test func bluetoothAirPlayAndTheSpeakerNeverGetIt() {
        for port in ["BluetoothA2DPOutput", "BluetoothLE", "Speaker", "Receiver", "AirPlay", "CarAudio"] {
            // Even at the song's own rate and full volume.
            let route = PhoneRoute(name: "x", portType: port, sampleRate: 192_000, channels: 2, spatial: false, uid: "usb:fiio-k11")
            #expect(!playing(on: route).untouched, "\(port)")
        }
    }

    @Test func anythingVespertineDoesToTheSoundTakesItBack() {
        // A gain or an equalizer sets this (ReplayGain, an EQ): the words go while it is on and come back when it is off.
        var signal = playing()
        signal.processed = true
        #expect(!signal.untouched && !signal.verifiedOnDAC)
        signal.processed = false
        #expect(signal.untouched)
        // A surround song folded, rendered for headphones, or spread over an interface's outputs.
        for mode in [SpatialModeChoice.off, .fixed, .headTracked] {
            var folded = playing()
            folded.surround = mode
            #expect(!folded.untouched)
        }
        var discrete = playing()
        discrete.discreteOutputs = 6
        #expect(!discrete.untouched)
    }

    @Test func aCopyTheMacMadeALossyFileOrAnotherChannelCountIsNotIt() {
        #expect(!playing(stream(kind: .flac)).untouched, "converted on the Mac")
        #expect(!playing(stream(lossless: false)).untouched)
        #expect(!playing(stream(channels: 1)).untouched, "a mono song on two outputs")
        #expect(!playing(stream(rate: 176_400, kind: .flac, dsd: 2_822_400), on: dac(rate: 176_400)).untouched, "DoP has its own badge")
    }

    @Test func verifiedNeedsThisDacToHavePassedTheTestAtThisSongsRate() {
        var dacs = DoPDACs()
        var run = DoPTestRun(uid: "usb:fiio-k11", name: "K11")
        for result in [DoPDACs.CarrierResult.passed, .passed, .hiss, .declined] { _ = run.finish(result, into: &dacs) }
        func verified(rate: Double, bits: Int? = 24, uid: String? = "usb:fiio-k11", volume: Double? = 1, outputRate: Double? = nil) -> Bool {
            let route = dac(rate: outputRate ?? rate, uid: uid)
            var signal = playing(stream(rate: rate, bits: bits), on: route, volume: volume)
            signal.dacPassedAtRate = dacs.passed(at: rate, for: route.uid)
            return signal.verifiedOnDAC
        }
        #expect(verified(rate: 176_400) && verified(rate: 192_000) && verified(rate: 192_000, bits: 16))
        // Rates the test didn't pass at, and rates it can't be played at (DoP starts at 176.4 kHz).
        #expect(!verified(rate: 352_800) && !verified(rate: 384_000))
        #expect(!verified(rate: 44_100) && !verified(rate: 96_000))
        // Another DAC, however alike.
        #expect(!verified(rate: 192_000, uid: "usb:other"))
        // The test carries 24 bits: nothing is said for a song with more, or with an unknown depth.
        #expect(!verified(rate: 192_000, bits: 32) && !verified(rate: 192_000, bits: nil))
        // And everything that takes "untouched" back takes this back too.
        #expect(!verified(rate: 192_000, volume: 0.8))
        #expect(!verified(rate: 192_000, outputRate: 96_000))
        var plain = playing()
        #expect(plain.untouched && !plain.verifiedOnDAC, "passing has to be said, never assumed")
        plain.dacPassedAtRate = true
        plain.processed = true
        #expect(!plain.verifiedOnDAC)
    }
}

@Suite struct TheDoPTestSound {
    /// The chord, without the second of DSD silence that leads into it.
    private static let frames = DoPProbeClip.chord()

    @Test func itIsFiveSecondsOfDoPFramesWithTheMarkerAlternatingThroughout() {
        let frames = Self.frames
        #expect(frames.count == 882_000 && frames.count % 2 == 0)
        var wrong = 0
        for (index, word) in frames.enumerated() where word >> 16 != (index % 2 == 0 ? 0x05 : 0xFA) { wrong += 1 }
        #expect(wrong == 0)
        #expect(frames.allSatisfy { $0 <= 0xFF_FFFF })
    }

    /// The DSD the frames carry, decoded as a DAC would: the mean of each 16 bits is one sample at 176.4 kHz, averaged
    /// again over 16 of those to take the modulator's noise out (11 kHz wide: plenty for a chord under 1 kHz).
    private static func decoded() -> [Double] {
        let raw = frames.map { word -> Double in
            let ones = (word & 0xFFFF).nonzeroBitCount
            return Double(2 * ones - 16) / 16
        }
        return stride(from: 0, to: raw.count - 15, by: 16).map { start in raw[start..<start + 16].reduce(0, +) / 16 }
    }

    @Test func aDacThatDecodesItPlaysASoftChordThatRisesFromSilenceAndEndsInIt() {
        let audio = Self.decoded()
        let rate = 176_400.0 / 16
        func peak(_ from: Double, _ to: Double) -> Double { audio[Int(from * rate)..<Int(to * rate)].map(abs).max() ?? 0 }
        // Nothing at the very start or the very end: no click when it begins or stops.
        #expect(peak(0, 0.05) < 0.02 && peak(4.95, 5.0) < 0.02)
        // It rises: quieter in the first half second than once it is up.
        #expect(peak(0.1, 0.5) < peak(2.5, 4.0))
        // The chord is there, and never above -20 dB of full scale (with a little room for what's left of the noise).
        #expect(peak(2.5, 4.0) > 0.04 && peak(0, 5.0) < DoPProbeClip.amplitude * 1.3)
        // The first note is C5: its level over a second of the held chord, by Goertzel.
        let held = Array(audio[Int(3.0 * rate)..<Int(4.0 * rate)])
        func level(_ hz: Double) -> Double {
            let w = 2 * Double.pi * hz / rate
            var re = 0.0, im = 0.0
            for (n, x) in held.enumerated() { re += x * cos(w * Double(n)); im += x * sin(w * Double(n)) }
            return 2 * (re * re + im * im).squareRoot() / Double(held.count)
        }
        #expect(level(523.25) > 0.02 && level(659.25) > 0.02 && level(783.99) > 0.02)
        #expect(level(2_000) < 0.005, "and nothing where no note is")
    }

    @Test func aDacThatDoesNotDecodeItPlaysOnlyAQuietHiss() {
        // Played as 24-bit PCM, the marker alternates every frame: a tone at 88.2 kHz, far above hearing. What can be
        // heard is what the 16 DSD bits under it add up to: averaged over two frames the marker is gone.
        let samples = Self.frames.map { Double(Int32(bitPattern: $0 << 8) >> 8) / 8_388_608 }
        var sum = 0.0
        var count = 0
        for index in stride(from: 0, to: samples.count - 1, by: 2) {
            let audible = (samples[index] + samples[index + 1]) / 2
            sum += audible * audible
            count += 1
        }
        let decibels = 20 * log10((sum / Double(count)).squareRoot())
        #expect(decibels < -42, "got \(decibels) dBFS")
    }

    @Test func theSameChordIsMadeForEveryCarrierRate() {
        for carrier in DoPDACs.testCarriers.dropFirst() {
            let frames = DoPProbeClip.chord(carrier: carrier)
            #expect(frames.count == Int(carrier * DoPProbeClip.seconds) && frames.count % 2 == 0, "\(carrier)")
            var wrong = 0
            for (index, word) in frames.enumerated() where word >> 16 != (index % 2 == 0 ? 0x05 : 0xFA) || word > 0xFF_FFFF { wrong += 1 }
            #expect(wrong == 0, "\(carrier)")
            // Decoded as a DAC would (the mean of each frame's 16 bits, then of 32 frames): the chord's three notes, held,
            // at the level they have at the first rate, and nothing where no note is.
            let raw = frames.map { Double(2 * ($0 & 0xFFFF).nonzeroBitCount - 16) / 16 }
            let audio = stride(from: 0, to: raw.count - 31, by: 32).map { start in raw[start..<start + 32].reduce(0, +) / 32 }
            let rate = carrier / 32
            let held = Array(audio[Int(3.0 * rate)..<Int(4.0 * rate)])
            func level(_ hz: Double) -> Double {
                let w = 2 * Double.pi * hz / rate
                var re = 0.0, im = 0.0
                for (n, x) in held.enumerated() { re += x * cos(w * Double(n)); im += x * sin(w * Double(n)) }
                return 2 * (re * re + im * im).squareRoot() / Double(held.count)
            }
            #expect(level(523.25) > 0.02 && level(659.25) > 0.02 && level(783.99) > 0.02, "\(carrier)")
            #expect(level(2_000) < 0.005, "\(carrier)")
            #expect((audio.map(abs).max() ?? 1) < DoPProbeClip.amplitude * 1.3, "\(carrier)")
            #expect((audio.prefix(Int(0.05 * rate)).map(abs).max() ?? 1) < 0.02 && (audio.suffix(Int(0.05 * rate)).map(abs).max() ?? 1) < 0.02, "\(carrier)")
        }
        // The first rate's clip is what it always was.
        #expect(DoPProbeClip.chord(carrier: 176_400).prefix(4_000) == Self.frames.prefix(4_000))
    }

    // TestFlight ACYG3aqcmGHtjCSJhP8P45c: "i actually didn't hear anything at all on some of these runs", on a DAC whose
    // display showed DSD64 and DSD128. The chord used to start with the first frame the DAC got.
    @Test func theChordIsLedInByASecondOfDsdSilenceThatIsValidDoP() {
        for carrier in DoPDACs.testCarriers {
            let frames = DoPProbeClip.frames(carrier: carrier)
            let lead = DoPProbeClip.leadFrames(carrier: carrier)
            #expect(lead == Int(carrier * DoPProbeClip.leadIn) && lead % 2 == 0, "\(carrier)")
            #expect(DoPProbeClip.leadIn >= 1)
            #expect(frames.count == lead + Int(carrier * DoPProbeClip.seconds), "\(carrier)")
            // The marker alternates from the first frame of the lead-in to the last of the chord, with no break
            // where one ends and the other begins.
            var wrong = 0
            for (index, word) in frames.enumerated() where word >> 16 != (index % 2 == 0 ? 0x05 : 0xFA) || word > 0xFF_FFFF { wrong += 1 }
            #expect(wrong == 0, "\(carrier)")
            // The lead-in is DSD silence: 0x69 in both bytes, as many ones as zeros, which a DAC decodes to nothing.
            #expect(frames.prefix(lead).allSatisfy { $0 & 0xFFFF == 0x6969 }, "\(carrier)")
            #expect(DoPProbeClip.idle.nonzeroBitCount == 4)
            // And the chord after it is the chord as it always was.
            #expect(Array(frames.dropFirst(lead).prefix(4_000)) == Array(DoPProbeClip.chord(carrier: carrier).prefix(4_000)), "\(carrier)")
        }
    }

    @Test func playedAsPCMTheLeadInIsQuietToo() {
        let lead = DoPProbeClip.leadFrames()
        let samples = DoPProbeClip.frames().prefix(lead).map { Double(Int32(bitPattern: $0 << 8) >> 8) / 8_388_608 }
        var sum = 0.0
        for index in stride(from: 0, to: samples.count - 1, by: 2) {
            let audible = (samples[index] + samples[index + 1]) / 2
            sum += audible * audible
        }
        let decibels = 20 * log10((sum / Double(samples.count / 2)).squareRoot())
        // A constant, far below full scale: nothing a speaker moves to.
        #expect(decibels < -42, "got \(decibels) dBFS")
    }

    @Test func aFrameSurvivesTheFloatSampleItIsSentAs() {
        // What an output makes of the float: scaled back to 24 bits, the same word.
        var wrong = 0
        for word in Self.frames.prefix(50_000) + Self.frames.suffix(50_000) {
            let back = UInt32(bitPattern: Int32((DoPProbeClip.sample(word) * 8_388_608).rounded())) & 0xFF_FFFF
            if back != word { wrong += 1 }
        }
        #expect(wrong == 0)
    }
}

#if canImport(Network) && canImport(AVFAudio)
import AVFAudio
import VespertineRemoteClient

/// A Mac that sends every song as a short made sound, and says it is DoP frames when asked for DoP at or above `carrier`
/// (the sound's own rate stands in for the carrier rate). It keeps what it was asked.
private final class DoPMac: @unchecked Sendable {
    struct Ask: Equatable { var song: Int64; var dop: Double? }
    private let lock = NSLock()
    private var open: [Int: Data] = [:]
    private var next = 0
    private var _asks: [Ask] = []
    private var _closed: [Int] = []
    let carrier = Double(DemoSound.sampleRate)
    let seconds: Double
    /// Songs that are PCM whatever is asked.
    var pcmSongs: Set<Int64> = []
    /// The ReplayGain values the Mac has for every song.
    var replayGain: ReplayGain?

    init(seconds: Double = 3) { self.seconds = seconds }

    private var _holding = false
    /// While set, every ask is answered "still preparing, 1%".
    var holding: Bool {
        get { lock.withLock { _holding } }
        set { lock.withLock { _holding = newValue } }
    }

    var asks: [Ask] { lock.withLock { _asks } }
    var closed: [Int] { lock.withLock { _closed } }

    func answer(_ song: Int64, dop: Double?) -> RemoteReply {
        if holding { return .streamPreparing(progress: 0.01) }
        let data = DemoSound.wave(song: song, seconds: seconds)
        let asDoP = !pcmSongs.contains(song) && (dop.map { $0 >= carrier - 0.5 } ?? false)
        return lock.withLock {
            _asks.append(Ask(song: song, dop: dop))
            next += 1
            open[next] = data
            return .streamOpened(StreamDescriptor(stream: next, kind: asDoP ? .flac : .original, byteSize: Int64(data.count),
                                                  format: StreamFormat(codec: "WAV", container: "wav", sampleRate: carrier, bitDepth: 16, channels: 2,
                                                                       channelLabels: nil, lossless: true),
                                                  frames: Int64((data.count - 44) / 4), tag: "\(song)-\(asDoP ? "dop" : "pcm")",
                                                  chunkSize: RemoteProtocol.defaultChunkSize, dsdRate: asDoP ? 2_822_400 : nil))
        }
    }

    var client: PhoneStreamClient {
        var client = PhoneStreamClient(open: { [self] song, _ in answer(song, dop: nil) },
                                       read: { [self] stream, offset, length in
                                           guard let data = lock.withLock({ open[stream] }), offset >= 0, offset <= Int64(data.count) else { throw RemoteLinkError.closed }
                                           let end = min(Int(offset) + max(0, length), data.count)
                                           return StreamFrame(request: 0, stream: stream, offset: offset, endOfStream: end >= data.count,
                                                              payload: data.subdata(in: Int(offset)..<end))
                                       },
                                       close: { [self] stream in lock.withLock { open[stream] = nil; _closed.append(stream) } },
                                       isConnected: { true })
        client.openDoP = { [self] song, _, dop in answer(song, dop: dop) }
        client.info = { [self] song in
            let format = StreamFormat(codec: "DSD", container: "dsf", sampleRate: 2_822_400, bitDepth: 1, channels: 2, channelLabels: nil, lossless: true)
            return StreamInfo(id: song, streamable: true, kind: .flac, source: format, delivered: nil, macOnlyReason: nil, byteSize: nil, totalFrames: nil,
                              replayGain: replayGain, encoderDelay: nil, endPadding: nil)
        }
        return client
    }
}

/// The output as the tests set it.
@MainActor private final class FakeOutput {
    var ceiling: Double?
    var rate: Double = 48_000
    /// What `bring` does: true moves the output to the rate asked for.
    var grants = true
    var brought: [Double] = []
    var declined: [Double] = []
    /// Why DSD is PCM on this output (`DoPGate.reason`), as the tests set it beside `ceiling`.
    var reason: DoPGate.PCMReason?
    /// Called inside `bring`, before it answers.
    var whileBringing: (() -> Void)?

    func install(on playback: PhonePlayback) {
        // Weak, not unowned: a test that gives up leaves its player running a moment longer than this output, and asking a
        // dead output must not take every other test down with it.
        playback.dop.ceiling = { [weak self] in self?.ceiling }
        playback.dop.rate = { [weak self] in self?.rate }
        playback.dop.bring = { [weak self] carrier in
            guard let self else { return false }
            brought.append(carrier)
            whileBringing?()
            if grants { rate = carrier }
            return grants
        }
        playback.dop.declined = { [weak self] carrier in self?.declined.append(carrier) }
        playback.dop.reason = { [weak self] _ in self?.reason }
    }
}

@Suite(.serialized) @MainActor struct ASongThatArrivesAsDoP {
    private func track(_ id: Int64) -> TrackSummary {
        TrackSummary(id: id, title: "Song \(id)", artist: "Artist", album: "Album", albumKey: "a", duration: 3, trackNumber: Int(id), discNumber: 1,
                     format: "DSD64", artworkKey: nil, favorite: false)
    }

    private func make(_ mac: DoPMac) throws -> (PhonePlayback, FakeOutput) {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!,
                                             maximumFrameCount: 4096)
        let playback = PhonePlayback(client: mac.client, player: PhonePlayer(engine: engine),
                                     cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("phone-dop-\(UUID())"))
        let output = FakeOutput()
        output.install(on: playback)
        return (playback, output)
    }

    /// Waits for something the phone must get round to. The 500 looks end a run where it never does; they decide nothing. They are counted, not timed: a busy machine that holds every test still for seconds uses up a clock but not a count.
    private func until(_ condition: () -> Bool) async throws {
        var looks = 0
        while !condition(), looks < 500 { looks += 1; try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    @Test func withoutATestedDacNothingIsEverAskedForAsDoP() async throws {
        let mac = DoPMac()
        let (playback, output) = try make(mac)
        playback.play([track(1), track(2)])
        try await until { playback.player.state == .playing && mac.asks.count == 2 }
        #expect(mac.asks == [.init(song: 1, dop: nil), .init(song: 2, dop: nil)])
        #expect(playback.stream?.dsdRate == nil && output.brought.isEmpty)
        playback.stop()
    }

    @Test func theOutputIsBroughtToTheCarrierRateBeforeTheSongStarts() async throws {
        let mac = DoPMac()
        let (playback, output) = try make(mac)
        output.ceiling = 768_000
        var stateWhileBringing: PhonePlayer.State?
        output.whileBringing = { stateWhileBringing = playback.player.state }
        playback.play([track(1)])
        try await until { playback.player.state == .playing }
        #expect(mac.asks == [.init(song: 1, dop: 768_000)])
        #expect(output.brought == [mac.carrier] && output.declined.isEmpty)
        #expect(stateWhileBringing == .idle, "nothing of the song is played while the output changes rate")
        #expect(playback.stream?.dsdRate == 2_822_400)
        playback.stop()
    }

    @Test func aDacThatWillNotRunAtTheCarrierRateGetsTheSongAsPCMAndIsNotAskedAgain() async throws {
        let mac = DoPMac()
        let (playback, output) = try make(mac)
        output.ceiling = 768_000
        output.grants = false
        playback.play([track(1)])
        try await until { playback.player.state == .playing }
        #expect(mac.asks == [.init(song: 1, dop: 768_000), .init(song: 1, dop: nil)])
        #expect(output.declined == [mac.carrier])
        #expect(playback.stream?.dsdRate == nil, "what plays is the PCM")
        try await until { mac.closed == [1] }   // and the DoP stream was given back to the Mac
        playback.stop()
    }

    @Test func theSongAfterItComesAsDoPOnlyWhileTheOutputRunsAtItsRate() async throws {
        let mac = DoPMac()
        let (playback, output) = try make(mac)
        output.ceiling = 768_000
        playback.play([track(1), track(2)])
        try await until { playback.player.state == .playing && mac.asks.count == 2 }
        // The first song brought the output to the carrier rate, so the one after it is asked for at exactly that rate.
        #expect(mac.asks == [.init(song: 1, dop: 768_000), .init(song: 2, dop: mac.carrier)], "\(mac.asks)")
        #expect(output.brought == [mac.carrier], "the output is not touched for a song opened ahead")
        playback.stop()
    }

    @Test func aDsdSongAfterAPcmSongAtAnotherRateIsNotAskedForAsDoP() async throws {
        // Nothing may change under the song being heard, so the DSD song lined up behind it comes as PCM.
        let mac = DoPMac()
        mac.pcmSongs = [10]
        let (playback, output) = try make(mac)
        output.ceiling = 768_000
        output.rate = 40_000
        playback.play([track(10), track(2)])
        try await until { playback.player.state == .playing && mac.asks.count == 2 }
        // Asked for only up to the rate the output runs at, which is below the song's carrier: it comes as PCM.
        #expect(mac.asks == [.init(song: 10, dop: 768_000), .init(song: 2, dop: 40_000)])
        #expect(output.brought.isEmpty && playback.stream?.dsdRate == nil)
        try await until { playback.player.state == .playing }
        playback.next()
        try await until { playback.nowPlaying?.track.id == 2 && playback.player.state == .playing }
        #expect(playback.stream?.dsdRate == nil && output.brought.isEmpty)
        playback.stop()
    }

    // TestFlight AB79Gu1HWKT1C1C9lmqSb_A: "this says converting on the mac, but this player very clearly supports DSD",
    // for a DSD64 song on a DAC that had just passed the DoP test. One "Converting on the Mac…" stood for every wait.
    @Test func aDsdSongAskedForAsDoPIsSaidToBePreparedAsDoPNotConverted() async throws {
        let mac = DoPMac()
        let (playback, output) = try make(mac)
        playback.pollInterval = .milliseconds(5)
        output.ceiling = 768_000
        mac.holding = true
        playback.play([track(1)])
        try await until { playback.preparing != nil }
        #expect(playback.preparing?.kind == .dop && playback.preparing?.progress == 0.01)
        mac.holding = false
        try await until { playback.player.state == .playing }
        #expect(playback.preparing == nil && playback.stream?.dsdRate != nil)
        #expect(playback.dsdAsPCM == nil, "it is DSD: there is nothing to give a reason for")
        playback.stop()
    }

    @Test func aDsdSongAskedForAsPCMSaysSoAndWhy() async throws {
        for reason in [DoPGate.PCMReason.notTested, .volume, .notADAC, .failedTest] {
            let mac = DoPMac()
            let (playback, output) = try make(mac)
            playback.pollInterval = .milliseconds(5)
            output.ceiling = nil
            output.reason = reason
            mac.holding = true
            playback.play([track(1)])
            try await until { playback.preparing != nil }
            #expect(playback.preparing?.kind == .dsdAsPCM(reason))
            mac.holding = false
            try await until { playback.player.state == .playing }
            #expect(mac.asks == [.init(song: 1, dop: nil)], "and nothing was asked for as DoP")
            // The reason stays with the song while it plays as PCM.
            #expect(playback.stream?.dsdRate == nil && playback.dsdAsPCM == reason)
            playback.stop()
            #expect(playback.dsdAsPCM == nil)
        }
    }

    @Test func aDacThatWillNotRunAtTheCarrierRateIsTheReasonTheSongIsPCM() async throws {
        let mac = DoPMac()
        let (playback, output) = try make(mac)
        playback.pollInterval = .milliseconds(5)
        output.ceiling = 768_000
        output.grants = false
        var kinds: [PhonePlayback.Preparing.Kind] = []
        // The second ask (the PCM one) is held, so what the wait is called can be read.
        output.whileBringing = { mac.holding = true }
        playback.play([track(1)])
        try await until { playback.preparing != nil }
        if let kind = playback.preparing?.kind { kinds.append(kind) }
        mac.holding = false
        try await until { playback.player.state == .playing }
        #expect(kinds == [.dsdAsPCM(.declined)])
        #expect(playback.stream?.dsdRate == nil && playback.dsdAsPCM == .declined)
        playback.stop()
    }

    @Test func aSongThatIsNotDsdIsAConversionWithNoDsdReason() async throws {
        let mac = DoPMac()
        mac.pcmSongs = [7]
        let (playback, output) = try make(mac)
        playback.pollInterval = .milliseconds(5)
        output.ceiling = 768_000
        mac.holding = true
        playback.play([TrackSummary(id: 7, title: "Song", artist: "Artist", album: "Album", albumKey: "a", duration: 3, trackNumber: 1, discNumber: 1,
                                    format: "DTS · 5.1", artworkKey: nil, favorite: false)])
        try await until { playback.preparing != nil }
        #expect(playback.preparing?.kind == .conversion)
        mac.holding = false
        try await until { playback.player.state == .playing }
        #expect(playback.dsdAsPCM == nil)
        playback.stop()
    }

    // TestFlight AA0UDi09-2p4lRKsNesXlK8, the DoP half: a fall back to PCM is said, and a volume that comes back does not
    // flip the song to DoP again behind the listener's back.
    @Test func aSongBroughtBackAsPCMSaysWhyAndStaysPCMWhenTheVolumeComesBack() async throws {
        let mac = DoPMac(seconds: 6)
        let (playback, output) = try make(mac)
        output.ceiling = 768_000
        playback.play([track(1)])
        try await until { playback.player.state == .playing && playback.stream?.dsdRate != nil }
        #expect(playback.dsdAsPCM == nil)
        output.ceiling = nil
        output.reason = .volume
        playback.outputChanged()
        try await until { playback.stream != nil && playback.stream?.dsdRate == nil && playback.player.state == .playing }
        #expect(playback.dsdAsPCM == .volume)
        let asked = mac.asks.count
        // Back at the top: this song carries on as PCM, and still says why it is.
        output.ceiling = 768_000
        output.reason = nil
        playback.outputChanged()
        try await Task.sleep(for: .milliseconds(50))
        #expect(mac.asks.count == asked && playback.stream?.dsdRate == nil && playback.player.state == .playing)
        #expect(playback.dsdAsPCM == .volume)
        playback.stop()
    }

    @Test func turningTheVolumeDownMidSongBringsTheSongBackAsPCMWhereItWas() async throws {
        let mac = DoPMac(seconds: 6)
        let (playback, output) = try make(mac)
        output.ceiling = 768_000
        playback.play([track(1)])
        try await until { playback.player.state == .playing && playback.stream?.dsdRate != nil }
        playback.seek(to: 2)
        try await until { abs(playback.livePosition - 2) < 0.2 }
        // The volume leaves its top: the output takes no DoP any more.
        output.ceiling = nil
        playback.outputChanged()
        try await until { playback.stream != nil && playback.stream?.dsdRate == nil && playback.player.state == .playing }
        #expect(mac.asks.last == .init(song: 1, dop: nil))
        #expect(abs(playback.livePosition - 2) < 0.3, "it carries on from where it was, at \(playback.livePosition)")
        #expect(playback.nowPlaying?.track.id == 1 && playback.notice == nil)
        playback.stop()
    }

    @Test func aPausedSongStaysPausedWhenItIsBroughtBackAsPCM() async throws {
        let mac = DoPMac(seconds: 6)
        let (playback, output) = try make(mac)
        output.ceiling = 768_000
        playback.play([track(1)])
        try await until { playback.player.state == .playing }
        playback.pause()
        output.ceiling = nil
        playback.outputChanged()
        try await until { playback.stream != nil && playback.stream?.dsdRate == nil && playback.player.state != .loading && playback.player.state != .idle }
        #expect(!playback.isPlaying)
        playback.stop()
    }

    @Test func aPcmSongIsLeftAloneWhenTheOutputChanges() async throws {
        let mac = DoPMac()
        let (playback, output) = try make(mac)
        playback.play([track(1)])
        try await until { playback.player.state == .playing }
        output.rate = 96_000
        playback.outputChanged()
        output.ceiling = 768_000
        playback.outputChanged()
        #expect(mac.asks == [.init(song: 1, dop: nil)] && playback.player.state == .playing)
        playback.stop()
    }

    @Test func aSongLinedUpAsDoPIsLinedUpAgainAsPCMWhenTheOutputStopsTakingDoP() async throws {
        let mac = DoPMac(seconds: 8)
        let (playback, output) = try make(mac)
        output.ceiling = 768_000
        playback.play([track(1), track(2)])
        try await until { playback.player.state == .playing && mac.asks.count == 2 }
        // The first song goes on as it is only if it isn't DoP itself: here it is, so both come back as PCM.
        output.ceiling = nil
        playback.outputChanged()
        try await until { playback.stream != nil && playback.stream?.dsdRate == nil && playback.player.state == .playing && mac.asks.count >= 4 }
        #expect(mac.asks.suffix(2).allSatisfy { $0.dop == nil })
        #expect(Set(mac.asks.suffix(2).map(\.song)) == [1, 2])
        playback.stop()
    }

    @Test func replayGainNeverTouchesDoPFramesButLevelsTheSameSongSentAsPCM() async throws {
        let mac = DoPMac()
        mac.replayGain = ReplayGain(trackGain: -6, trackPeak: 0.5, albumGain: nil, albumPeak: nil)
        let (playback, output) = try make(mac)
        output.ceiling = 768_000
        playback.replayGain = .track
        playback.play([track(1)])
        try await until { playback.player.state == .playing }
        // The frames are DSD bits: multiplying them would be noise. Nothing is done, and the phone says nothing is.
        #expect(playback.stream?.dsdRate == 2_822_400)
        #expect(playback.appliedGain == nil && playback.player.gain == 1 && !playback.player.isProcessing)
        #expect(playback.replayGainHasNothing)
        // The DAC stops taking DoP: the song comes back as PCM, and now it is levelled.
        output.ceiling = nil
        playback.outputChanged()
        try await until { playback.stream != nil && playback.stream?.dsdRate == nil && playback.player.state == .playing }
        #expect(playback.appliedGain?.decibels == -6 && playback.player.isProcessing)
        #expect(abs(playback.player.gain - Float(pow(10, -6.0 / 20))) < 1e-6)
        playback.stop()
    }
}

@Suite @MainActor struct WhatThePhoneSaysAboutDoP {
    private func descriptor(dsd: Double?) -> StreamDescriptor {
        StreamDescriptor(stream: 1, kind: .flac, byteSize: 10,
                         format: StreamFormat(codec: "FLAC", container: "flac", sampleRate: 176_400, bitDepth: 24, channels: 2, channelLabels: nil, lossless: true),
                         frames: 10, tag: "t", chunkSize: 1, dsdRate: dsd)
    }

    @Test func theSignalSaysDsdOnlyForAStreamTheMacSentAsDoP() {
        var signal = PhoneSignal(stream: descriptor(dsd: 2_822_400), route: dac(rate: 176_400))
        signal.volume = 1
        #expect(signal.dsdRate == 2_822_400 && !signal.dopBroken)
        #expect(PhoneSignal(stream: descriptor(dsd: nil), route: dac(rate: 176_400)).dsdRate == nil)
        // At another rate, or with the volume down, the DAC is not getting DSD, and the signal says so.
        #expect(PhoneSignal(stream: descriptor(dsd: 2_822_400), route: dac(rate: 96_000)).dopBroken)
        signal.volume = 0.5
        #expect(signal.dopBroken)
    }
}
#endif
