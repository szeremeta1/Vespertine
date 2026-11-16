//
// Vespertine: the ReplayGain rules on the phone: which of a file's values is used, how the peak holds a gain down, and
// that Off (and a file that says nothing) leaves a song alone.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteProtocol
@testable import VespertinePhonePlayer

@Suite struct ReplayGainRules {
    private let both = ReplayGain(trackGain: -6.2, trackPeak: 0.98, albumGain: -4.5, albumPeak: 0.99)

    @Test func offDoesNothingWhateverTheFileSays() {
        #expect(PhoneReplayGain.applied(both, choice: .off) == nil)
    }

    @Test func aFileThatSaysNothingIsLeftAlone() {
        #expect(PhoneReplayGain.applied(nil, choice: .track) == nil)
        #expect(PhoneReplayGain.applied(ReplayGain(trackGain: nil, trackPeak: 0.5, albumGain: nil, albumPeak: nil), choice: .album) == nil)
        #expect(PhoneReplayGain.applied(ReplayGain(trackGain: .nan, trackPeak: nil, albumGain: nil, albumPeak: nil), choice: .track) == nil)
    }

    @Test func eachChoiceUsesItsOwnGain() throws {
        let track = try #require(PhoneReplayGain.applied(both, choice: .track))
        #expect(track.decibels == -6.2 && !track.heldByPeak)
        #expect(track.scale == Float(pow(10, -6.2 / 20)))
        let album = try #require(PhoneReplayGain.applied(both, choice: .album))
        #expect(album.decibels == -4.5 && album.scale == Float(pow(10, -4.5 / 20)))
    }

    @Test func theOtherKindStandsInWhenTheFileHasOnlyThatOne() {
        let trackOnly = ReplayGain(trackGain: -3, trackPeak: nil, albumGain: nil, albumPeak: nil)
        #expect(PhoneReplayGain.applied(trackOnly, choice: .album)?.decibels == -3)
        let albumOnly = ReplayGain(trackGain: nil, trackPeak: nil, albumGain: -8, albumPeak: nil)
        #expect(PhoneReplayGain.applied(albumOnly, choice: .track)?.decibels == -8)
    }

    @Test func aGainUpIsHeldSoThePeakStaysUnderFullScale() throws {
        // +6 dB would take a 0.8 peak to 1.6: only 1 / 0.8 is allowed.
        let quiet = ReplayGain(trackGain: 6, trackPeak: 0.8, albumGain: nil, albumPeak: nil)
        let applied = try #require(PhoneReplayGain.applied(quiet, choice: .track))
        #expect(applied.heldByPeak)
        #expect(abs(applied.decibels - 20 * log10(1 / 0.8)) < 1e-9)
        #expect(Double(applied.scale) * 0.8 <= 1, "not even rounding lets the peak through")
        #expect(Double(applied.scale) * 0.8 > 0.9999)
        // With room to spare the gain is the file's own.
        let roomy = ReplayGain(trackGain: 2, trackPeak: 0.5, albumGain: nil, albumPeak: nil)
        #expect(PhoneReplayGain.applied(roomy, choice: .track) == AppliedGain(decibels: 2, scale: Float(pow(10, 2.0 / 20)), heldByPeak: false))
    }

    @Test func aPeakAtFullScaleLeavesAGainUpWithNothingToDo() {
        let full = ReplayGain(trackGain: 4, trackPeak: 1, albumGain: nil, albumPeak: nil)
        #expect(PhoneReplayGain.applied(full, choice: .track) == nil, "0 dB is no change: the song is not said to be processed")
    }

    @Test func aGainDownIsNeverHeld() throws {
        let hot = ReplayGain(trackGain: -9, trackPeak: 1.2, albumGain: nil, albumPeak: nil)
        let applied = try #require(PhoneReplayGain.applied(hot, choice: .track))
        #expect(applied.decibels == -9 && !applied.heldByPeak)
    }

    @Test func gainsStayWithinTheMacPlayersLimits() {
        #expect(PhoneReplayGain.applied(ReplayGain(trackGain: -60, trackPeak: nil, albumGain: nil, albumPeak: nil), choice: .track)?.decibels == -30)
        #expect(PhoneReplayGain.applied(ReplayGain(trackGain: 40, trackPeak: nil, albumGain: nil, albumPeak: nil), choice: .track)?.decibels == 15)
    }

    @Test func zeroDecibelsIsNoChange() {
        #expect(PhoneReplayGain.applied(ReplayGain(trackGain: 0, trackPeak: 0.7, albumGain: nil, albumPeak: nil), choice: .track) == nil)
    }
}
