//
// Vespertine: what the phone does when iOS interrupts it (a call, Siri, an alarm) and which rate it asks a DAC for.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

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
}
