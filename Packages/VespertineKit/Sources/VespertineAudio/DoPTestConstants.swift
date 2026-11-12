//
// Vespertine: every tunable number and every word of the one-tap DoP test, in one place.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Limits and wording for the first-DSD test (`DoPTestSession`). The numbers that decide how loud the test can be and
/// the words the listener reads are PLACEHOLDERS until the maintainer picks them: change them here and nowhere else.
/// `DoPSetupTests` pins the safety relations between them (every volume option under the ceiling, and so on), so a new
/// pick that breaks one fails the tests instead of shipping.
public enum DoPTestConstants {
    // MARK: Level (PLACEHOLDER: the maintainer picks the volume)

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

    // MARK: Words (PLACEHOLDERS: the maintainer picks the wording; English only until then, translated once final)

    public struct Wording: Sendable, Hashable {
        /// Heading of the card shown under the signal path while DSD is being converted on an unknown DAC.
        public var offerTitle: String
        /// Body when nothing is known about the maker.
        public var offerBody: String
        /// Body when the maker is on the DSD list; `%@` is the maker's name.
        public var suggestBody: String
        public var testButton: String
        public var listening: String
        public var question: String
        public var musicButton: String
        public var hissButton: String
        public var cancelButton: String
        public var musicResult: String
        public var hissResult: String
        public var abortedDeviceChanged: String
        public var notPlayedAsDoP: String
    }

    /// Three candidate wordings: A plain and short, B reassuring, C technical.
    public static let wordingOptions: [Wording] = [
        Wording(
            offerTitle: "Play DSD natively?",
            offerBody: "This DAC isn't on the list of DACs known to take DSD over PCM (DoP), so DSD is being converted to PCM. A short, quiet test can tell.",
            suggestBody: "%@ makes DACs that play DSD, so this one may take DoP. A short, quiet test can tell.",
            testButton: "Test DoP",
            listening: "Playing a short, quiet test…",
            question: "Did you hear music or hiss?",
            musicButton: "Music",
            hissButton: "Hiss",
            cancelButton: "Cancel",
            musicResult: "DoP is on for this DAC.",
            hissResult: "DoP stays off for this DAC. DSD keeps playing as PCM.",
            abortedDeviceChanged: "The test stopped because an audio device changed. Nothing was saved.",
            notPlayedAsDoP: "The test couldn't play as DoP on this output, so nothing was saved."),
        Wording(
            offerTitle: "Try native DSD on this DAC",
            offerBody: "Vespertine doesn't know whether this DAC understands DoP, a way to send DSD over PCM, so it plays DSD as PCM for now. You can try a very short, soft test. If the DAC doesn't understand it, you'll hear a little hiss at most.",
            suggestBody: "%@ makes DSD-capable DACs, so this one may well take DoP. Try a very short, soft test; at worst you'll hear a little hiss.",
            testButton: "Try a soft test",
            listening: "Playing a soft test sound…",
            question: "What did you hear?",
            musicButton: "Soft music",
            hissButton: "Hiss",
            cancelButton: "Not now",
            musicResult: "Great. DSD will play natively on this DAC.",
            hissResult: "Okay. DSD will keep playing as PCM on this DAC.",
            abortedDeviceChanged: "An audio device changed during the test, so it was stopped and nothing was saved.",
            notPlayedAsDoP: "This output couldn't play the test as DoP, so nothing was saved."),
        Wording(
            offerTitle: "DoP test",
            offerBody: "USB DACs don't report DoP support. Vespertine can play a 5-second DSD64 clip over DoP at a capped volume to check this DAC. Music means it decodes DoP; hiss means it doesn't.",
            suggestBody: "%@ DACs commonly decode DoP. Vespertine can play a 5-second DSD64 clip over DoP at a capped volume to check this one.",
            testButton: "Run test",
            listening: "Playing DSD64 over DoP at a capped volume…",
            question: "Music or hiss?",
            musicButton: "Music",
            hissButton: "Hiss",
            cancelButton: "Cancel",
            musicResult: "Saved: DoP on for this DAC.",
            hissResult: "Saved: DoP off for this DAC.",
            abortedDeviceChanged: "Aborted: the audio device list or default output changed. Nothing saved.",
            notPlayedAsDoP: "Aborted: the engine did not use DoP for this clip. Nothing saved."),
    ]

    /// The wording in use.
    public static let wording: Wording = wordingOptions[0]
}
