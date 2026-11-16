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

    @Test func replayGainIsOffUntilChosenAndAChoiceIsKept() {
        #expect(PlayTarget.replayGain(stored: nil) == .off)
        #expect(PlayTarget.replayGain(stored: "nonsense") == .off)
        #expect(PlayTarget.replayGain(stored: "track") == .track && PlayTarget.replayGain(stored: "album") == .album)
    }

    @Test func theOutputScreenSaysWhatReplayGainDoesToTheSongOnlyWhileItIsOn() {
        // Off: no row at all.
        #expect(!PlayTarget.report(signal(rate: 44_100, route: dac), route: dac).contains { $0.label == "ReplayGain" })
        var said = signal(rate: 44_100, route: dac)
        said.replayGain = -6.2
        said.processed = true
        #expect(PlayTarget.report(said, route: dac).first { $0.label == "ReplayGain" }?.value == "−6.2 dB")
        said.replayGain = 1.5
        #expect(PlayTarget.report(said, route: dac).first { $0.label == "ReplayGain" }?.value == "+1.5 dB")
        // On, and this song has nothing to go by: said, so the row isn't taken for a fault.
        said.replayGain = nil
        said.replayGainHasNothing = true
        #expect(PlayTarget.report(said, route: dac).first { $0.label == "ReplayGain" }?.value == "None for this song")
    }
}
