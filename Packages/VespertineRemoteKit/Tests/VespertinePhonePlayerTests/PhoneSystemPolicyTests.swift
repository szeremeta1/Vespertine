//
// Vespertine: what the phone does when iOS interrupts it (a call, Siri, an alarm) and which rate it asks a DAC for.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertinePhonePlayer

@Suite struct PhoneSystemPolicyTests {
    @Test func aCallPausesAndTheMusicComesBackWhenIOSSaysItMay() {
        var policy = InterruptionPolicy()
        #expect(policy.began(isPlaying: true) == .pause)
        #expect(policy.ended(shouldResume: true) == .resume)
        // Once resumed, a second "ended" does nothing.
        #expect(policy.ended(shouldResume: true) == .nothing)
    }

    @Test func musicThatWasPausedStaysPausedAfterACall() {
        var policy = InterruptionPolicy()
        #expect(policy.began(isPlaying: false) == .nothing)
        #expect(policy.ended(shouldResume: true) == .nothing)
    }

    @Test func iOSNotAllowingAResumeLeavesItPaused() {
        var policy = InterruptionPolicy()
        _ = policy.began(isPlaying: true)
        #expect(policy.ended(shouldResume: false) == .nothing)
    }

    @Test func pausingByHandDuringACallCancelsTheResume() {
        var policy = InterruptionPolicy()
        _ = policy.began(isPlaying: true)
        policy.userActed()
        #expect(policy.ended(shouldResume: true) == .nothing)
    }

    @Test func unpluggingHeadphonesPausesButANewOutputDoesNot() {
        #expect(RouteChangePolicy.pauses(reason: .oldDeviceUnavailable))
        #expect(!RouteChangePolicy.pauses(reason: .newDeviceAvailable))
        #expect(!RouteChangePolicy.pauses(reason: .other))
    }

    @Test func surroundIsRenderedForHeadphonesAndFoldedForEverythingElse() {
        let pods = PhoneRoute(name: "AirPods Max", portType: "BluetoothA2DPOutput", sampleRate: 48_000, channels: 2, spatial: true)
        let plain = PhoneRoute(name: "Headphones", portType: "Headphones", sampleRate: 48_000, channels: 2, spatial: false)
        let speaker = PhoneRoute(name: "Speaker", portType: "Speaker", sampleRate: 48_000, channels: 2, spatial: false)
        let tv = PhoneRoute(name: "Living Room", portType: "AirPlay", sampleRate: 48_000, channels: 2, spatial: false)
        #expect(pods.surroundMode(wanted: .headTracked) == .headTracked)
        #expect(pods.surroundMode(wanted: .fixed) == .fixed)
        #expect(pods.surroundMode(wanted: .off) == .off)
        // Headphones that don't follow your head get the fixed rendering, and say so.
        #expect(plain.surroundMode(wanted: .headTracked) == .fixed)
        // Speakers get the plain fold: a binaural rendering is made for ears, not for a room.
        #expect(speaker.surroundMode(wanted: .headTracked) == .off)
        #expect(tv.surroundMode(wanted: .fixed) == .off)
    }

    @Test func onlyADACIsAskedForTheSongsRate() {
        let dac = PhoneRoute(name: "K11", portType: "USBAudio", sampleRate: 48_000, channels: 2, spatial: false)
        let wired = PhoneRoute(name: "Headphones", portType: "Headphones", sampleRate: 48_000, channels: 2, spatial: false)
        let pods = PhoneRoute(name: "AirPods Max", portType: "BluetoothA2DPOutput", sampleRate: 48_000, channels: 2, spatial: true)
        let speaker = PhoneRoute(name: "Speaker", portType: "Speaker", sampleRate: 48_000, channels: 2, spatial: false)
        #expect(dac.rateToAsk(for: 96_000) == 96_000)
        #expect(wired.rateToAsk(for: 44_100) == 44_100)
        // Already there: nothing to ask.
        #expect(dac.rateToAsk(for: 48_000) == nil)
        // Bluetooth and the built-in speaker run at iOS's rate: asking breaks Bluetooth links.
        #expect(pods.rateToAsk(for: 96_000) == nil)
        #expect(speaker.rateToAsk(for: 96_000) == nil)
    }

    // MARK: DACs

    private func dac(_ rate: Double, channels: Int = 2, most: Int? = nil, name: String = "K11") -> PhoneRoute {
        PhoneRoute(name: name, portType: "USBAudio", sampleRate: rate, channels: channels, spatial: false, maximumChannels: most)
    }

    @Test func theLadderIsTheSongsRateThenItsHalves() {
        #expect(RateLadder.rungs(for: 192_000) == [192_000, 96_000, 48_000])
        #expect(RateLadder.rungs(for: 352_800) == [352_800, 176_400, 88_200, 44_100])
        #expect(RateLadder.rungs(for: 44_100) == [44_100])
        #expect(RateLadder.rungs(for: 0).isEmpty)
    }

    @Test func aDACThatTakesTheSongsRateIsAskedOnce() {
        var ladder = RateLadder()
        #expect(ladder.begin(route: dac(48_000), songRate: 192_000) == 192_000)
        // The same song, the same output: not asked again while iOS thinks about it.
        #expect(ladder.begin(route: dac(48_000), songRate: 192_000) == nil)
        #expect(ladder.declined(route: dac(192_000)) == nil)
    }

    @Test func aDACThatDeclinesIsAskedForTheNextRungDown() {
        var ladder = RateLadder()
        #expect(ladder.begin(route: dac(48_000), songRate: 352_800) == 352_800)
        // Still at 48 kHz a moment later: 352.8 was declined.
        #expect(ladder.declined(route: dac(48_000)) == 176_400)
        #expect(ladder.declined(route: dac(176_400)) == nil)
    }

    @Test func theLadderEndsRatherThanAskingForever() {
        var ladder = RateLadder()
        #expect(ladder.begin(route: dac(48_000), songRate: 88_200) == 88_200)
        #expect(ladder.declined(route: dac(48_000)) == 44_100)
        #expect(ladder.declined(route: dac(48_000)) == nil)
        #expect(ladder.declined(route: dac(48_000)) == nil)
    }

    @Test func aRungTheOutputIsAlreadyAtIsNotAskedFor() {
        var ladder = RateLadder()
        #expect(ladder.begin(route: dac(96_000), songRate: 192_000) == 192_000)
        // Declined, and the DAC already sits at the next rung.
        #expect(ladder.declined(route: dac(96_000)) == nil)
    }

    @Test func aNewSongOrAnotherOutputStartsFromTheTop() {
        var ladder = RateLadder()
        _ = ladder.begin(route: dac(48_000), songRate: 192_000)
        _ = ladder.declined(route: dac(48_000))
        #expect(ladder.begin(route: dac(48_000), songRate: 44_100) == 44_100)
        #expect(ladder.begin(route: dac(48_000, name: "Other"), songRate: 44_100) == 44_100)
        // A song already at the output's rate asks for nothing.
        #expect(ladder.begin(route: dac(96_000), songRate: 96_000) == nil)
    }

    @Test func bluetoothAndTheSpeakerAreNeverOnTheLadder() {
        var ladder = RateLadder()
        let pods = PhoneRoute(name: "AirPods", portType: "BluetoothA2DPOutput", sampleRate: 48_000, channels: 2, spatial: true)
        #expect(ladder.begin(route: pods, songRate: 96_000) == nil)
        #expect(ladder.declined(route: pods) == nil)
    }

    @Test func aSurroundSongAsksAnInterfaceForChannelsOfItsOwn() {
        // A 5.1 interface running with two channels: ask for six.
        #expect(dac(48_000, channels: 2, most: 6).channelsToAsk(for: 6) == 6)
        // 7.1 on a 5.1 interface: all it has.
        #expect(dac(48_000, channels: 2, most: 6).channelsToAsk(for: 8) == 6)
        // Already there, a stereo song, or a stereo DAC: nothing to ask.
        #expect(dac(48_000, channels: 6, most: 6).channelsToAsk(for: 6) == nil)
        #expect(dac(48_000, channels: 2, most: 6).channelsToAsk(for: 2) == nil)
        #expect(dac(48_000).channelsToAsk(for: 6) == nil)
        let pods = PhoneRoute(name: "AirPods", portType: "BluetoothA2DPOutput", sampleRate: 48_000, channels: 2, spatial: true, maximumChannels: 8)
        #expect(pods.channelsToAsk(for: 6) == nil)
    }

    @Test func aMultichannelInterfaceGetsTheChannelsNotABinauralRendering() {
        let interface = dac(48_000, channels: 6, most: 6)
        #expect(interface.isMultichannel)
        #expect(!interface.isHeadphones)
        #expect(interface.surroundMode(wanted: .headTracked) == .off)
        // A stereo DAC usually feeds headphones.
        #expect(dac(48_000).surroundMode(wanted: .fixed) == .fixed)
    }

    @Test func aDACGivingWayToTheSpeakerPausesHoweverIOSTellsIt() {
        let speaker = PhoneRoute(name: "Speaker", portType: "Speaker", sampleRate: 48_000, channels: 2, spatial: false)
        let pods = PhoneRoute(name: "AirPods", portType: "BluetoothA2DPOutput", sampleRate: 48_000, channels: 2, spatial: true)
        #expect(RouteChangePolicy.pauses(from: dac(96_000), to: speaker))
        #expect(RouteChangePolicy.pauses(from: pods, to: speaker))
        #expect(RouteChangePolicy.pauses(from: dac(96_000), to: nil))
        // The DAC changing its rate, or headphones taking over from the speaker, is not an unplugging.
        #expect(!RouteChangePolicy.pauses(from: dac(48_000), to: dac(96_000)))
        #expect(!RouteChangePolicy.pauses(from: speaker, to: pods))
        #expect(!RouteChangePolicy.pauses(from: dac(96_000), to: pods))
        #expect(!RouteChangePolicy.pauses(from: nil, to: speaker))
    }
}

@Suite struct PositionAnchorTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aSongPlayingOnIsNotNews() {
        var anchor = PositionAnchor(position: 10, at: start, moving: true)
        // Four readings a second for a minute, each where the clock says it should be (give or take a buffer).
        var told = 0
        for step in 1...240 {
            let elapsed = Double(step) * 0.25
            if anchor.read(10 + elapsed + (step % 2 == 0 ? 0.02 : -0.02), moving: true, at: start.addingTimeInterval(elapsed)) { told += 1 }
        }
        #expect(told == 0)
        #expect(anchor.position == 10 && anchor.at == start)
        #expect(abs(anchor.expected(at: start.addingTimeInterval(60)) - 70) < 0.001)
    }

    @Test func aSeekAStallAndAPauseAreNews() {
        var anchor = PositionAnchor(position: 10, at: start, moving: true)
        // A seek.
        let told1 = anchor.read(95, moving: true, at: start.addingTimeInterval(1))
        #expect(told1)
        #expect(anchor.position == 95 && anchor.at == start.addingTimeInterval(1))
        // The song stops moving (it ran out of what had arrived): told once, then quiet while it waits.
        let told2 = anchor.read(96, moving: false, at: start.addingTimeInterval(2))
        #expect(told2)
        let told3 = anchor.read(96, moving: false, at: start.addingTimeInterval(30))
        #expect(!told3)
        #expect(anchor.expected(at: start.addingTimeInterval(30)) == 96)
        // And moves again.
        let told4 = anchor.read(96, moving: true, at: start.addingTimeInterval(31))
        #expect(told4)
        let told5 = anchor.read(97, moving: true, at: start.addingTimeInterval(32))
        #expect(!told5)
    }

    @Test func aSongThatDriftsFromTheClockIsPutRight() {
        var anchor = PositionAnchor(position: 0, at: start, moving: true)
        let told6 = anchor.read(1.2, moving: true, at: start.addingTimeInterval(1))
        #expect(!told6)
        let told7 = anchor.read(1.4, moving: true, at: start.addingTimeInterval(1))
        #expect(told7)
        #expect(anchor.position == 1.4)
    }
}
