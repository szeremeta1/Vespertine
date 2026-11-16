//
// Vespertine Remote: what the Output screen and the signal chips say about a DAC: the rate iOS gave, the channels, and a
// volume that isn't at its top. Facts read back, never a claim.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertinePhonePlayer
import VespertineRemoteProtocol
@testable import VespertineRemote

@MainActor @Suite struct OutputReport {
    private func signal(rate: Double, channels: Int = 2, route: PhoneRoute?) -> PhoneSignal {
        let format = StreamFormat(codec: "FLAC", container: "flac", sampleRate: rate, bitDepth: 24, channels: channels, channelLabels: nil, lossless: true)
        return PhoneSignal(stream: StreamDescriptor(stream: 1, kind: .original, byteSize: 10, format: format, frames: 10, tag: "t", chunkSize: 1), route: route)
    }
    private let dac = PhoneRoute(name: "K11", portType: "USBAudio", sampleRate: 192_000, channels: 2, spatial: false)

    @Test func aSongAtTheDACsRateIsNotCalledResampled() {
        let rows = PlayTarget.report(signal(rate: 192_000, route: dac), route: dac)
        #expect(rows.first { $0.label == "Song" }?.value == "24/192")
        #expect(rows.first { $0.label == "Output runs at" }?.value == "192 kHz")
        #expect(rows.first { $0.label == "Resampled by iOS" }?.value == "No")
        #expect(rows.first { $0.label == "Output" }?.value == "K11")
    }

    @Test func aRateTheDACDeclinedIsSaid() {
        var declined = dac
        declined.sampleRate = 96_000
        let said = signal(rate: 192_000, route: declined)
        #expect(PlayTarget.report(said, route: declined).first { $0.label == "Resampled by iOS" }?.value == "Yes")
        #expect(PlayTarget.output(said) == "96 kHz, resampled by iOS")
    }

    @Test func aVolumeBelowTheTopIsSaidOnADACOnly() {
        var said = signal(rate: 192_000, route: dac)
        said.volume = 0.8
        #expect(PlayTarget.output(said).hasPrefix("192 kHz · volume 80"))
        #expect(PlayTarget.report(said, route: dac).contains { $0.label == "Volume" })
        said.volume = 1
        #expect(PlayTarget.output(said) == "192 kHz")
        let pods = PhoneRoute(name: "AirPods", portType: "BluetoothA2DPOutput", sampleRate: 48_000, channels: 2, spatial: true)
        var onPods = signal(rate: 48_000, route: pods)
        onPods.volume = 0.5
        #expect(PlayTarget.output(onPods) == "48 kHz")
    }

    @Test func surroundOnAnInterfaceSaysAChannelToEachOutput() {
        let interface = PhoneRoute(name: "Interface", portType: "USBAudio", sampleRate: 48_000, channels: 6, spatial: false, maximumChannels: 6)
        var said = signal(rate: 48_000, channels: 6, route: interface)
        said.discreteOutputs = 6
        #expect(PlayTarget.badge(said) == "SURROUND ON 6 OUTPUTS")
        let rows = PlayTarget.report(said, route: interface)
        #expect(rows.first { $0.label == "Surround" }?.value == "A channel to each output")
        #expect(rows.first { $0.label == "Output’s channels" }?.value == "6")
        #expect(rows.first { $0.label == "Song’s channels" }?.value == "6")
    }

    // MARK: Surround on headphones: asked for, and named as what plays

    @Test func someoneWhoNeverChoseGetsNoSpatialRendering() {
        #expect(PlayTarget.surround(stored: nil) == .off)
        #expect(PlayTarget.surround(stored: "nonsense") == .off)
        // A choice made before this was Off by default is kept.
        #expect(PlayTarget.surround(stored: "headTracked") == .headTracked)
        #expect(PlayTarget.surround(stored: "fixed") == .fixed)
    }

    @Test func theOutputScreenNamesWhatIsDoneToASurroundSongOnHeadphones() {
        let pods = PhoneRoute(name: "AirPods Max", portType: "BluetoothA2DPOutput", sampleRate: 48_000, channels: 2, spatial: true)
        var said = signal(rate: 48_000, channels: 6, route: pods)
        said.surround = .fixed
        #expect(PlayTarget.badge(said) == "SPATIAL AUDIO · FIXED")
        #expect(PlayTarget.report(said, route: pods).first { $0.label == "Surround on Headphones" }?.value == "Fixed")
        said.surround = .headTracked
        #expect(PlayTarget.report(said, route: pods).first { $0.label == "Surround on Headphones" }?.value == "Head Tracked")
        said.surround = .off
        #expect(PlayTarget.badge(said) == "SURROUND FOLDED TO STEREO")
        #expect(PlayTarget.report(said, route: pods).first { $0.label == "Surround on Headphones" }?.value == "Off")
        // A two-channel song has no such row: nothing is done to it.
        #expect(!PlayTarget.report(signal(rate: 48_000, route: pods), route: pods).contains { $0.label == "Surround on Headphones" })
        // Nor has a speaker, where surround is always folded.
        let speaker = PhoneRoute(name: "Speaker", portType: "Speaker", sampleRate: 48_000, channels: 2, spatial: false)
        var folded = signal(rate: 48_000, channels: 6, route: speaker)
        folded.surround = .off
        #expect(!PlayTarget.report(folded, route: speaker).contains { $0.label == "Surround on Headphones" })
    }

    // MARK: The original file on a DAC: what is said, and what takes it back

    private let tested = PhoneRoute(name: "K11", portType: "USBAudio", sampleRate: 192_000, channels: 2, spatial: false, uid: "usb:k11")
    private var results: DoPDACs {
        var dacs = DoPDACs()
        var run = DoPTestRun(uid: "usb:k11", name: "K11")
        for result in [DoPDACs.CarrierResult.passed, .passed, .hiss, .declined] { _ = run.finish(result, into: &dacs) }
        return dacs
    }
    private func original(rate: Double = 192_000, on route: PhoneRoute, volume: Double? = 1, passed: Bool = false) -> PhoneSignal {
        var said = signal(rate: rate, route: route)
        said.volume = volume
        said.dacPassedAtRate = passed
        return said
    }

    @Test func theBadgeSaysNoProcessingOnlyWhileNothingChangesTheSamples() {
        #expect(PlayTarget.badge(original(on: tested)) == "ORIGINAL FILE · NO PROCESSING")
        // The volume below 100%.
        #expect(PlayTarget.badge(original(on: tested, volume: 0.8)) == "ORIGINAL FILE")
        #expect(PlayTarget.badge(original(on: tested, volume: nil)) == "ORIGINAL FILE")
        // Resampled by iOS.
        #expect(PlayTarget.badge(original(rate: 96_000, on: tested)) == "ORIGINAL FILE")
        // Bluetooth and the speaker.
        let pods = PhoneRoute(name: "AirPods Max", portType: "BluetoothA2DPOutput", sampleRate: 192_000, channels: 2, spatial: true)
        let speaker = PhoneRoute(name: "Speaker", portType: "Speaker", sampleRate: 192_000, channels: 2, spatial: false)
        #expect(PlayTarget.badge(original(on: pods)) == "ORIGINAL FILE" && PlayTarget.badge(original(on: speaker)) == "ORIGINAL FILE")
        // A gain or an equalizer in Vespertine.
        var gained = original(on: tested, passed: true)
        gained.processed = true
        #expect(PlayTarget.badge(gained) == "ORIGINAL FILE")
    }

    @Test func theBadgeSaysVerifiedOnlyOnADacThatPassedAtTheSongsRate() {
        #expect(PlayTarget.badge(original(on: tested, passed: true)) == "ORIGINAL FILE · VERIFIED ON THIS DAC")
        #expect(PlayTarget.badge(original(on: tested, volume: 0.8, passed: true)) == "ORIGINAL FILE")
        #expect(PlayTarget.badge(original(rate: 96_000, on: tested, passed: true)) == "ORIGINAL FILE")
        let rows = PlayTarget.report(original(on: tested, passed: true), route: tested, dop: results)
        #expect(rows.first { $0.label == "Original file" }?.value == "Verified on this DAC")
        #expect(PlayTarget.report(original(on: tested), route: tested).first { $0.label == "Original file" }?.value == "No processing")
        #expect(!PlayTarget.report(original(on: tested, volume: 0.8), route: tested).contains { $0.label == "Original file" })
        for words in [PlayTarget.badge(original(on: tested)), PlayTarget.badge(original(on: tested, passed: true))] + rows.flatMap({ [$0.label, $0.value] }) {
            #expect(!words.lowercased().contains("bit-perfect") && !words.lowercased().contains("bit perfect"))
        }
    }

    @Test func theOutputScreenListsTheRatesTheDacPassedTheDoPTestAt() {
        let rows = PlayTarget.report(original(on: tested), route: tested, dop: results)
        #expect(rows.first { $0.label == "DoP passed at" }?.value == "176.4, 192 kHz")
        #expect(rows.first { $0.label == "DoP not passed at" }?.value == "352.8, 384 kHz")
        // Another DAC, and one never tested, get no such rows.
        #expect(!PlayTarget.report(original(on: dac), route: dac, dop: results).contains { $0.label.hasPrefix("DoP") })
        #expect(PlayTarget.dopRows(DoPDACs(), route: tested).isEmpty)
        var hiss = DoPDACs()
        hiss.record(.hiss, uid: "usb:k11", name: "K11")
        #expect(PlayTarget.dopRows(hiss, route: tested).map(\.label) == ["DoP not passed at"])
    }
}
