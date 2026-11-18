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
        let wired = PhoneRoute(name: "Headphones", portType: "Headphones", sampleRate: 48_000, channels: 2, spatial: false)
        // Vespertine's own rendering, for headphones iOS doesn't spatialize: never called iOS's Spatial Audio.
        var own = signal(rate: 48_000, channels: 6, route: wired)
        own.surround = .fixed
        #expect(PlayTarget.badge(own) == "BINAURAL · FIXED")
        #expect(PlayTarget.report(own, route: wired).first { $0.label == "Surround on Headphones" }?.value == "Rendered by Vespertine, fixed")
        var said = signal(rate: 48_000, channels: 6, route: pods)
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

    // MARK: Surround handed to iOS (tf-1c99555e54, tf-4e0452d141, tf-a5b2a6dbdc)

    @Test func spatialAudioIsClaimedOnlyWhenIOSSaysIt() {
        let pods = PhoneRoute(name: "AirPods Max", portType: "BluetoothA2DPOutput", sampleRate: 48_000, channels: 2, spatial: true)
        var said = signal(rate: 48_000, channels: 6, route: pods)
        said.systemChannels = 6
        said.systemRendering = .spatialAudio
        #expect(PlayTarget.badge(said) == "SPATIAL AUDIO")
        let rows = PlayTarget.report(said, route: pods)
        #expect(rows.first { $0.label == "Channels sent to iOS" }?.value == "6")
        #expect(rows.first { $0.label == "iOS renders it as" }?.value == "Spatial Audio")
        #expect(rows.first { $0.label == "Spatial Audio on this output" }?.value == "On")
        #expect(rows.first { $0.label == "Surround on Headphones" }?.value == "Spatial Audio by iOS")
        // Never "head tracked" or "fixed": that is Control Center's choice, which iOS doesn't tell apps.
        #expect(!rows.contains { $0.value.localizedCaseInsensitiveContains("head tracked") || $0.value == "Fixed" })
        said.systemRendering = .dolbyAtmos
        #expect(PlayTarget.badge(said) == "SPATIAL AUDIO · DOLBY ATMOS")
        said.systemRendering = .monoStereo
        #expect(PlayTarget.badge(said) == "SURROUND · iOS PLAYS STEREO")
        #expect(PlayTarget.report(said, route: pods).first { $0.label == "iOS renders it as" }?.value == "Stereo")
        said.systemRendering = nil
        #expect(PlayTarget.badge(said) == "SURROUND TO iOS · SPATIAL AUDIO ON")
        var off = pods
        off.spatial = false
        var unspatial = signal(rate: 48_000, channels: 6, route: off)
        unspatial.systemChannels = 6
        unspatial.systemRendering = .spatialAudio
        #expect(PlayTarget.badge(unspatial) == "SURROUND · 6 CHANNELS TO iOS")
    }

    @Test func thePickerOffersOffAndSpatialAudio() {
        #expect(PlayTarget.surroundChoices == [.off, .fixed])
        // A Head Tracked choice kept from build 7 is Spatial Audio now: head tracking is chosen in Control Center.
        #expect(PlayTarget.pickerValue(.headTracked) == .fixed && PlayTarget.pickerValue(.fixed) == .fixed && PlayTarget.pickerValue(.off) == .off)
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

    // MARK: The original file on a DAC: what is said, and what takes it back

    // TestFlight build 7: a 24/96 FLAC on a FiiO K11 showed "48 kHz" while the DAC's own display said 44.1 kHz, and the
    // volume chip stayed at 30% with the phone at 100%.
    @Test func aRateAskedForAndNotYetGivenIsShownAsSwitchingNeverAsSettled() {
        var before = dac
        before.sampleRate = 48_000
        var said = signal(rate: 96_000, route: before)
        said.pendingRate = 96_000
        said.volume = 0.3
        #expect(PlayTarget.output(said) == "switching to 96 kHz… · volume 30%")
        let rows = PlayTarget.report(said, route: before)
        #expect(rows.first { $0.label == "Asked iOS for" }?.value == "96 kHz")
        #expect(rows.first { $0.label == "Resampled by iOS" }?.value == "Waiting for iOS to switch")
        #expect(rows.first { $0.label == "Output runs at" }?.value == "48 kHz")
        // iOS gave it: one reading has the rate and the volume.
        var after = dac
        after.sampleRate = 96_000
        var settled = signal(rate: 96_000, route: after)
        settled.pendingRate = nil
        settled.volume = 0.3
        #expect(PlayTarget.output(settled) == "96 kHz · volume 30%")
        #expect(!PlayTarget.report(settled, route: after).contains { $0.label == "Asked iOS for" })
        settled.volume = 1
        #expect(PlayTarget.output(settled) == "96 kHz")
        #expect(PlayTarget.badge(settled) == "ORIGINAL FILE · NO PROCESSING")
        // iOS declined it: the rate it reports, and that it resamples.
        var declined = signal(rate: 96_000, route: before)
        declined.volume = 1
        #expect(PlayTarget.output(declined) == "48 kHz, resampled by iOS")
        #expect(PlayTarget.badge(declined) == "ORIGINAL FILE")
    }

    @Test func aVolumeIOSDoesNotReportIsSaidPlainly() {
        var said = signal(rate: 192_000, route: dac)
        said.volume = nil
        let rows = PlayTarget.report(said, route: dac)
        #expect(rows.first { $0.label == "Volume" }?.value == "Not reported by iOS")
        #expect(rows.first { $0.label == "Original file" }?.value == "Can’t say: iOS reports no volume")
        #expect(PlayTarget.badge(said) == "ORIGINAL FILE")
        // No output at all: no volume row to speak of.
        #expect(!PlayTarget.report(signal(rate: 192_000, route: nil), route: nil).contains { $0.label == "Volume" })
    }

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
        // Below 100% the row stays and says why the song's samples aren't what the DAC gets.
        #expect(PlayTarget.report(original(on: tested, volume: 0.8), route: tested).first { $0.label == "Original file" }?.value == "Changed by the volume (below 100%)")
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
