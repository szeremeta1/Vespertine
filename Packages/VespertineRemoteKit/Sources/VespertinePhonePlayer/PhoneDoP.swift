//
// Vespertine: DSD on a DAC plugged into the phone. A DAC is sent DSD as DoP (the song's own DSD bits behind a marker byte, in
// 24-bit samples) only after it passed a short listening test on this phone, and only while the output can carry the frames
// exactly: two channels, at the carrier rate, with the volume at its top. Otherwise the Mac converts DSD to PCM, as before.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//
// The rules and the test sound are plain Swift, apart from iOS, so the tests pin them anywhere.
//

import Foundation

/// Which DACs take DoP, as you answered the test for each. Kept by the output's own identifier (`PhoneRoute.uid`), so one
/// DAC's answer says nothing about another.
public struct DoPDACs: Codable, Equatable, Sendable {
    /// What you heard when the test sound was sent as DoP.
    public enum Answer: String, Codable, Sendable {
        /// A soft chord: the DAC decoded DoP, which it can only do if the frames reached it exactly as sent.
        case music
        /// Hiss or nothing: it played the frames as PCM, or something changed them on the way.
        case hiss
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var answer: Answer
        /// The DAC's name when it was tested, for showing.
        public var name: String
        /// The highest carrier rate it has been seen to run at, once a higher one was declined. nil: none declined yet.
        public var ceiling: Double?
    }

    /// The rate the test is played at: DSD64's carrier.
    public static let testCarrier = 176_400.0
    /// The highest carrier asked of a DAC that hasn't declined one: DSD256 (iOS goes no further).
    public static let highestCarrier = 768_000.0

    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    public func answer(for uid: String?) -> Answer? { uid.flatMap { entries[$0]?.answer } }

    /// The highest carrier rate to send this DAC DoP at, or nil when it gets none: not tested, or it answered hiss.
    public func ceiling(for uid: String?) -> Double? {
        guard let uid, let entry = entries[uid], entry.answer == .music else { return nil }
        return entry.ceiling ?? Self.highestCarrier
    }

    public mutating func record(_ answer: Answer, uid: String, name: String) {
        entries[uid] = Entry(answer: answer, name: name, ceiling: nil)
    }

    /// The DAC didn't run at `carrier` when asked: nothing above half of it is sent as DoP again. Declining the test's own
    /// rate takes the answer back altogether (it has to be tested again), since it then can't carry DoP at all.
    public mutating func declined(_ carrier: Double, uid: String) {
        guard var entry = entries[uid], entry.answer == .music else { return }
        let below = carrier / 2
        guard below >= Self.testCarrier - 0.5 else {
            entries[uid] = nil
            return
        }
        entry.ceiling = min(entry.ceiling ?? below, below)
        entries[uid] = entry
    }

    public mutating func forget(uid: String) { entries[uid] = nil }

    // MARK: Keeping

    public static let defaultsKey = "dopDACs"

    public static func load(from defaults: UserDefaults = .standard) -> DoPDACs {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(DoPDACs.self, from: $0) } ?? DoPDACs()
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// When the output may be sent DoP at all.
public enum DoPGate {
    /// The volume counts as at its top from here (iOS reports 1.0 as a float).
    public static let fullVolume = 0.995

    /// An output the DoP test can be run on: a USB DAC that iOS identifies and runs with two channels. Not Bluetooth,
    /// AirPlay or the speaker (they never carry samples exactly), and not an interface running with more outputs.
    public static func canTest(_ route: PhoneRoute?) -> Bool {
        guard let route, route.isUSB, !route.hasFixedRate, route.channels == 2, let uid = route.uid, !uid.isEmpty else { return false }
        return true
    }

    /// The highest carrier rate DSD may be asked for as DoP right now, or nil when it must be PCM: an output that can't be
    /// tested or hasn't passed, or a volume below the top (iOS may then be scaling the samples, which makes noise of DoP).
    /// An unknown volume counts as below the top.
    public static func ceiling(route: PhoneRoute?, volume: Double?, dacs: DoPDACs) -> Double? {
        guard canTest(route), let volume, volume >= fullVolume else { return nil }
        return dacs.ceiling(for: route?.uid)
    }

    /// For a song opened ahead of time, while another plays: DoP only up to the rate the output already runs at, so
    /// nothing has to change under the song being heard (at 44.1 or 48 kHz that is no DSD at all: the lowest carrier is
    /// 176.4). nil when the output takes no DoP, or runs above what the DAC takes it at.
    public static func aheadCeiling(ceiling: Double?, outputRate: Double?) -> Double? {
        guard let ceiling, let outputRate, outputRate > 0, outputRate <= ceiling + 0.5 else { return nil }
        return outputRate
    }

    /// "DSD64", "DSD128"… for a DSD rate; the 48 kHz family (3.072 MHz) is named the same way.
    public static func name(dsdRate: Double) -> String {
        let base = dsdRate.truncatingRemainder(dividingBy: 44_100) == 0 ? 44_100.0 : 48_000.0
        return "DSD\(Int((dsdRate / base).rounded()))"
    }
}

/// The sound the DoP test plays: five seconds of DSD64 made here (nothing to ship), a soft three-note chord that rises from
/// silence, already packed as DoP frames. A DAC that decodes DoP plays the chord. One that doesn't plays the frames as 24-bit
/// PCM: the marker alternates at 88.2 kHz, far above hearing, and the DSD bits sit in the low 16 bits, 42 dB or more under
/// full scale, so the worst case is a quiet hiss. The same recipe as the Mac's test (`DoPTestClip`).
public enum DoPProbeClip {
    public static let dsdRate = 2_822_400
    public static let carrierRate = 176_400.0
    public static let seconds = 5.0
    static let fadeIn = 1.5
    static let fadeOut = 0.5
    /// Peak of the chord as a fraction of DSD full scale (-20 dB).
    public static let amplitude = 0.1
    /// C5, E5, G5, each coming in a second after the one before.
    private static let notes: [(hz: Double, start: Double)] = [(523.25, 0), (659.25, 1.0), (783.99, 2.0)]

    static func envelope(at t: Double) -> Double {
        guard t > 0, t < seconds else { return 0 }
        func smooth(_ x: Double) -> Double { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }
        return amplitude * min(smooth(t / fadeIn), smooth((seconds - t) / fadeOut))
    }

    static func signal(at t: Double) -> Double {
        let level = envelope(at: t)
        guard level > 0 else { return 0 }
        var sum = 0.0
        for note in notes where t >= note.start {
            sum += min((t - note.start) / 0.3, 1) * sin(2 * Double.pi * note.hz * t)   // 0.3 s to come in: no click
        }
        return level * sum / Double(notes.count)
    }

    /// The clip's DSD bits for one channel, 8 to a byte, the oldest in the top bit; an even number of bytes.
    public static func dsd() -> [UInt8] {
        let samples = Int(seconds * Double(dsdRate))
        var bytes = [UInt8](repeating: 0, count: (samples + 15) / 16 * 2)
        // The signal changes every 64 DSD samples (44.1 kHz) and is drawn straight between: plenty for a chord under 1 kHz.
        let step = 64
        var v1 = 0.0, v2 = 0.0, y = 0.0
        var x0 = signal(at: 0), x1 = signal(at: Double(step) / Double(dsdRate))
        for i in 0..<samples {
            let k = i % step
            if k == 0, i > 0 { x0 = x1; x1 = signal(at: Double(i + step) / Double(dsdRate)) }
            let x = x0 + (x1 - x0) * Double(k) / Double(step)
            v1 += x - y                                              // a second-order sigma-delta modulator
            v2 += v1 - y
            y = v2 >= 0 ? 1 : -1
            if y > 0 { bytes[i >> 3] |= UInt8(0x80 >> (i & 7)) }
        }
        // Past the last sample, DSD silence (0x69: as many ones as zeros) fills the last frame.
        let whole = (samples + 7) / 8
        for index in whole..<bytes.count { bytes[index] = 0x69 }
        return bytes
    }

    /// One 24-bit DoP word: the marker (0x05, then 0xFA, alternating by frame), then 16 DSD bits, oldest first.
    public static func word(frame: Int, _ first: UInt8, _ second: UInt8) -> UInt32 {
        (frame & 1 == 0 ? 0x05 : 0xFA) << 16 | UInt32(first) << 8 | UInt32(second)
    }

    /// The clip as DoP frames, one word a frame (both channels carry the same).
    public static func frames() -> [UInt32] {
        let bits = dsd()
        return (0..<bits.count / 2).map { word(frame: $0, bits[2 * $0], bits[2 * $0 + 1]) }
    }

    /// A DoP word as the float sample that an output turns back into exactly that 24-bit word.
    public static func sample(_ word: UInt32) -> Float {
        Float(Int32(bitPattern: word << 8)) / 2_147_483_648
    }
}
