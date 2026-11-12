//
// Vespertine: every tunable number and every word of the one-tap DoP test, in one place.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Limits and wording for the first-DSD test (`DoPTestSession`), in one place: the numbers that decide how loud the test
/// can be and the words the listener reads (picked by the maintainer: wording A, a 20% cap).
/// `DoPSetupTests` pins the safety relations between them (every volume option under the ceiling, and so on), so a new
/// pick that breaks one fails the tests instead of shipping.
public enum DoPTestConstants {
    // MARK: Level (the maintainer's pick: B, 20%)

    /// A DAC that doesn't decode DoP plays the stream as 24-bit PCM, and DoP can't be made quieter digitally without
    /// breaking it. So the cap is applied to the device's own hardware volume (where it has one) for the length of the
    /// test, then put back; and the clip itself is built quiet (see `maxToneAmplitude`, `maxMisreadAudibleDBFS`).
    ///
    /// Hardware volume (0...1, Core Audio's scalar) the test lowers the DAC to, when it has a volume control and is
    /// above this. Never raised. The three candidates are `volumeOptions`.
    public static let hardwareVolumeCap: Float = volumeOptions[1]

    /// Candidate caps: A, quiet; B, low; C, moderate. All under `absoluteVolumeCeiling`.
    public static let volumeOptions: [Float] = [0.10, 0.20, 0.30]

    /// No pick, and no remote update, can set a cap above this: `DoPTestSafety.effectiveCap` clamps to it.
    public static let absoluteVolumeCeiling: Float = 0.30

    // MARK: The clip

    /// Length of the clip, fade-in and fade-out included.
    public static let clipSeconds: Double = 5
    /// The clip starts from silence and rises to full level over this long, in the DSD itself.
    public static let fadeInSeconds: Double = 1.5
    /// The same again at the end, so nothing ends on a click.
    public static let fadeOutSeconds: Double = 0.5
    /// Peak of the tones, as a fraction of DSD full scale (0.1 is -20 dB; the sigma-delta modulator stays stable well
    /// above that, so this is a musical choice, not a limit).
    public static let maxToneAmplitude: Double = 0.1
    /// What a DAC that does NOT decode DoP would play from this clip, measured in the audible band as RMS against full
    /// scale: the 16 DSD bits sit under the 8-bit marker, so a misread stream can't be louder than this. The test
    /// renders the clip, reads it as 24-bit PCM and fails above this number.
    public static let maxMisreadAudibleDBFS: Double = -45

    // MARK: Words (the maintainer's pick, wording A; localized in App/Resources/Localizable.xcstrings)

    /// What the card under the signal path and the test sheet say. Each is looked up when read, in the app's language.
    public struct Wording: Sendable {
        /// Heading of the card shown under the signal path while DSD is being converted on an unknown DAC.
        public var offerTitle: String { String(localized: "Play DSD natively?", comment: "DoP test card heading, under the signal path while DSD is converted to PCM on a DAC not known to take DoP.") }
        /// Body when nothing is known about the maker.
        public var offerBody: String { String(localized: "This DAC isn't on the list of DACs known to take DSD over PCM (DoP), so DSD is being converted to PCM. A short, quiet test can tell.", comment: "DoP test card text for a DAC whose maker isn't known for DSD DACs.") }
        /// Body when the maker is on the DSD list.
        public func suggestBody(maker: String) -> String {
            String(localized: "\(maker) makes DACs that play DSD, so this one may take DoP. A short, quiet test can tell.", comment: "DoP test card text. %@ is the DAC maker's name, e.g. FiiO.")
        }
        public var testButton: String { String(localized: "Test DoP", comment: "Button on the DoP test card: plays a short, quiet DSD test sound over DoP.") }
        public var listening: String { String(localized: "Playing a short, quiet test…", comment: "DoP test sheet while the test sound plays.") }
        public var question: String { String(localized: "Did you hear music or hiss?", comment: "DoP test sheet, after the test sound: music means the DAC decodes DoP, hiss means it doesn't.") }
        public var musicButton: String { String(localized: "Music", comment: "DoP test answer button: the test sound was heard as music.") }
        public var hissButton: String { String(localized: "Hiss", comment: "DoP test answer button: the test sound was heard as hiss or noise.") }
        public var cancelButton: String { String(localized: "Cancel") }
        public var musicResult: String { String(localized: "DoP is on for this DAC.", comment: "DoP test result after the listener answered Music.") }
        public var hissResult: String { String(localized: "DoP stays off for this DAC. DSD keeps playing as PCM.", comment: "DoP test result after the listener answered Hiss.") }
        public var abortedDeviceChanged: String { String(localized: "The test stopped because an audio device changed. Nothing was saved.", comment: "DoP test ended early: an output was plugged in or out, or the default output changed.") }
        public var notPlayedAsDoP: String { String(localized: "The test couldn't play as DoP on this output, so nothing was saved.", comment: "DoP test ended early: the engine didn't send the test sound as DoP.") }
    }

    /// The wording in use.
    public static let wording = Wording()
}
