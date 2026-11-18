//
// Vespertine: DSD on a DAC plugged into the phone. A DAC is sent DSD as DoP (the song's own DSD bits behind a marker byte, in
// 24-bit samples) only after it passed a short listening test on this phone, and only while the output can carry the frames
// exactly: two channels, at the carrier rate, with nothing scaling the samples (iOS's volume at its top, or at the level the
// chord was heard at on this DAC, which shows that level changes nothing). Otherwise the Mac converts DSD to PCM, as before.
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

    /// How the test went at one carrier rate.
    public enum CarrierResult: String, Codable, Sendable {
        /// You heard the chord: frames at this rate reached the DAC exactly as sent.
        case passed
        /// The DAC ran at the rate, and you heard hiss or nothing.
        case hiss
        /// The DAC wouldn't run at the rate.
        case declined
        /// Nothing was heard at the rate, twice: no sound, which is not the DAC failing to decode DoP. It is not sent
        /// DoP at a rate it wasn't heard at, and the rate can be tested again.
        case silent
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var answer: Answer
        /// The DAC's name when it was tested, for showing.
        public var name: String
        /// The highest carrier rate it has been seen to run at, once a higher one was declined. nil: none declined yet.
        public var ceiling: Double?
        /// How the test went at each carrier rate it was played at (the rate in Hz). nil: an answer from before the
        /// test played more than one rate, which says nothing about any rate but the first.
        public var carriers: [Int: CarrierResult]?
        /// iOS's volume while the chord was heard, when it was below the top (`DoPDACs.unreported` when iOS gave none).
        /// The chord is only heard if the frames arrive bit for bit, so at this level iOS changes nothing on the way
        /// to this DAC: its volume is set on the DAC. nil: heard with the volume at the top, which shows nothing more.
        public var level: Double?
    }

    /// `Entry.level` for a chord heard while iOS reported no volume at all.
    public static let unreported = -1.0
    /// How near iOS's volume has to be to the level the chord was heard at to count as that level.
    public static let levelTolerance = 0.005

    /// The rate the test is played at first, and the one that decides whether the DAC gets DoP at all: DSD64's carrier.
    public static let testCarrier = 176_400.0
    /// Every rate the test plays the chord at, in order: DSD64 and DSD128, each in the 44.1 and the 48 kHz family.
    public static let testCarriers = [176_400.0, 192_000.0, 352_800.0, 384_000.0]
    /// The highest carrier asked of a DAC that hasn't declined one: DSD256 (iOS goes no further).
    public static let highestCarrier = 768_000.0

    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    public func answer(for uid: String?) -> Answer? { uid.flatMap { entries[$0]?.answer } }

    /// The highest carrier rate to send this DAC DoP at, or nil when it gets none: not tested, or it answered hiss.
    public func ceiling(for uid: String?) -> Double? {
        guard let uid, let entry = entries[uid], entry.answer == .music else { return nil }
        var top = entry.ceiling ?? Self.highestCarrier
        // The ceiling is one rate, so the lowest rate the test didn't pass at stops everything from there up: DoP goes
        // only to rates below it.
        if let failed = entry.carriers?.filter({ $0.value != .passed }).keys.min() {
            guard let below = Self.testCarriers.last(where: { $0 < Double(failed) - 0.5 }) else { return nil }
            top = min(top, below)
        }
        return top
    }

    /// The first rate's answer, which starts this DAC's results afresh: music turns DoP on for it, hiss leaves it off.
    /// `volume`: iOS's volume while it was heard. A chord heard below the top is kept with that level.
    public mutating func record(_ answer: Answer, uid: String, name: String, volume: Double? = 1) {
        let level: Double? = answer == .music && !DoPGate.atTop(volume) ? (volume ?? Self.unreported) : nil
        entries[uid] = Entry(answer: answer, name: name, ceiling: nil, carriers: [Int(Self.testCarrier): answer == .music ? .passed : .hiss], level: level)
    }

    /// This DAC played the chord with iOS's volume at exactly this level, below the top: the level is not applied to
    /// what the DAC gets. Only that level is vouched for, never another.
    public func heardBelowTop(at volume: Double?, for uid: String?) -> Bool {
        guard let uid, let entry = entries[uid], entry.answer == .music, let level = entry.level else { return false }
        guard let volume else { return level == Self.unreported }
        return level != Self.unreported && abs(volume - level) <= Self.levelTolerance
    }

    /// Nothing is known to scale the samples on the way to this DAC with iOS's volume as it is: it is at the top, or at
    /// the level this DAC played the chord at.
    public func volumeIsOutOfTheWay(_ volume: Double?, for uid: String?) -> Bool {
        DoPGate.atTop(volume) || heardBelowTop(at: volume, for: uid)
    }

    /// How the test went at a rate above the first, for a DAC that passed the first. (The first rate's result is its
    /// answer: `record(_:uid:name:)`.)
    public mutating func record(_ result: CarrierResult, carrier: Double, uid: String) {
        guard var entry = entries[uid], entry.answer == .music, carrier > Self.testCarrier + 0.5 else { return }
        entry.carriers = (entry.carriers ?? [Int(Self.testCarrier): .passed]).merging([Int(carrier.rounded()): result]) { _, new in new }
        entries[uid] = entry
    }

    /// The rates the test was played at on this DAC, in the test's order, each with how it went. Empty for a DAC that
    /// hasn't been tested.
    public func results(for uid: String?) -> [(carrier: Double, result: CarrierResult)] {
        guard let uid, let entry = entries[uid] else { return [] }
        let carriers = entry.carriers ?? [Int(Self.testCarrier): entry.answer == .music ? .passed : .hiss]
        return Self.testCarriers.compactMap { carrier in carriers[Int(carrier)].map { (carrier, $0) } }
    }

    /// The rates nothing was heard at (`CarrierResult.silent`).
    public func silent(for uid: String?) -> [Double] { results(for: uid).filter { $0.result == .silent }.map(\.carrier) }

    /// The rates this DAC played the chord at.
    public func passed(for uid: String?) -> [Double] { results(for: uid).filter { $0.result == .passed }.map(\.carrier) }

    /// Whether this DAC played the chord at exactly `rate`: frames at that rate were shown to reach it as sent.
    public func passed(at rate: Double, for uid: String?) -> Bool { passed(for: uid).contains { abs($0 - rate) < 0.5 } }

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
        // A rate the test passed at, then declined while playing a song, is no longer said to have passed.
        let key = Int(carrier.rounded())
        if entry.carriers?[key] != nil { entry.carriers?[key] = .declined }
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

/// One run of the DoP test: the chord at each carrier rate in turn. The first rate decides whether the DAC gets DoP at
/// all, so the run ends there unless it passed; the rates after it are each recorded as they went, whatever the answer.
public struct DoPTestRun: Equatable, Sendable {
    /// What the listener says they heard.
    public enum Heard: String, Sendable, CaseIterable {
        /// The chord.
        case music
        /// Hiss or noise: the DAC played the frames as PCM, or something changed them on the way.
        case noise
        /// No sound at all. Not the same as hiss: a DAC that is still locking on, or muted, says nothing about DoP.
        case nothing
        /// Not sure: the same rate once more, nothing kept.
        case again
    }

    /// How a run ended.
    public enum Ending: Equatable, Sendable {
        /// The chord was heard at the first rate: DoP is on for the DAC (the later rates each have their own result).
        case on
        /// Hiss or noise at the first rate, with nothing else to blame: DoP stays off for the DAC.
        case off
        /// Nothing was heard at the first rate, twice. Not a failed test: nothing is kept, and what was known stays.
        case silent
        /// Hiss or noise while iOS's volume was below the top and not known to be out of the way: iOS scaling the
        /// samples would sound just like that, so it says nothing about the DAC. Nothing is kept.
        case inconclusive
    }

    /// What follows an answer.
    public enum Step: Equatable, Sendable {
        /// The same rate is played again.
        case replay
        /// The next rate is played.
        case next
        case ended(Ending)
    }

    public private(set) var remaining: [Double]
    public let uid: String
    public let name: String
    /// iOS's volume when the run began. The run only counts while it stays there.
    public let volume: Double?
    /// How many times in a row nothing was heard at the rate being played.
    public private(set) var silences = 0
    /// How many times "nothing" is answered at a rate before it is taken as the rate's result.
    public static let silencesToSettle = 2

    public init(uid: String, name: String, volume: Double? = 1, carriers: [Double] = DoPDACs.testCarriers) {
        self.uid = uid
        self.name = name
        self.volume = volume
        remaining = carriers
    }

    /// The rate being played, or nil when the run is over.
    public var carrier: Double? { remaining.first }
    public var isFirst: Bool { remaining.first == DoPDACs.testCarrier }

    /// The output is still the DAC under test, with two channels and iOS's volume where it was when the run began.
    public func holds(on now: OutputState) -> Bool {
        guard let route = now.route, route.uid == uid, route.channels == 2 else { return false }
        switch (volume, now.volume) {
        case (nil, nil): return true
        case let (was?, isNow?): return abs(was - isNow) <= DoPDACs.levelTolerance || (DoPGate.atTop(was) && DoPGate.atTop(isNow))
        default: return false
        }
    }

    /// Takes what was heard at the rate being played, keeps what it shows in `dacs`, and says what follows.
    public mutating func heard(_ heard: Heard, into dacs: inout DoPDACs) -> Step {
        guard carrier != nil else { return .ended(.on) }
        switch heard {
        case .again:
            return .replay
        case .nothing:
            silences += 1
            guard silences >= Self.silencesToSettle else { return .replay }
            return isFirst ? end(.silent) : step(finish(.silent, into: &dacs))
        case .noise:
            // With the volume below the top and not shown to be out of the way, iOS may be what made the noise.
            guard dacs.volumeIsOutOfTheWay(volume, for: uid) else { return end(.inconclusive) }
            let first = isFirst
            let more = finish(.hiss, into: &dacs)
            return first ? .ended(.off) : step(more)
        case .music:
            return step(finish(.passed, into: &dacs))
        }
    }

    private mutating func end(_ ending: Ending) -> Step {
        remaining = []
        return .ended(ending)
    }

    private func step(_ more: Bool) -> Step { more ? .next : .ended(.on) }

    /// Takes how the rate being played went, keeps it in `dacs`, and says whether another rate follows. A first rate the
    /// DAC wouldn't run at saves nothing, as before: the test couldn't be played at all.
    public mutating func finish(_ result: DoPDACs.CarrierResult, into dacs: inout DoPDACs) -> Bool {
        guard let carrier else { return false }
        silences = 0
        if isFirst {
            switch result {
            case .passed: dacs.record(.music, uid: uid, name: name, volume: volume)
            case .hiss: dacs.record(.hiss, uid: uid, name: name)
            case .declined, .silent: break
            }
            guard result == .passed else { remaining = []; return false }
        } else {
            dacs.record(result, carrier: carrier, uid: uid)
        }
        remaining.removeFirst()
        return !remaining.isEmpty
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

    /// iOS's volume is at its top. An unknown volume is not.
    public static func atTop(_ volume: Double?) -> Bool { volume.map { $0 >= fullVolume } ?? false }

    /// The highest carrier rate DSD may be asked for as DoP right now, or nil when it must be PCM: an output that can't be
    /// tested or hasn't passed, or a volume that may be scaling the samples (which makes noise of DoP). The volume is out
    /// of the way at its top, or at the level this very DAC played the test's chord at; an unknown volume, or any other
    /// level, counts as scaling.
    public static func ceiling(route: PhoneRoute?, volume: Double?, dacs: DoPDACs) -> Double? {
        guard canTest(route), dacs.volumeIsOutOfTheWay(volume, for: route?.uid) else { return nil }
        return dacs.ceiling(for: route?.uid)
    }

    /// Why a DSD song is played as PCM.
    public enum PCMReason: String, Equatable, Sendable {
        /// The output isn't a DAC the DoP test can run on (Bluetooth, AirPlay, the speaker, an interface with more outputs).
        case notADAC
        /// The DAC hasn't been tested.
        case notTested
        /// The DAC was tested and played hiss or noise.
        case failedTest
        /// iOS's volume is below its top and not shown to be out of the way.
        case volume
        /// The DAC passed, but not at the rate this song's DSD needs.
        case rate
        /// DoP was asked for and the DAC wouldn't run at the song's carrier rate.
        case declined
        /// The song was lined up to follow another without a gap while the DAC ran at another rate than its DoP needs:
        /// the rate can't change under the song being heard.
        case ahead
    }

    /// The carrier rate a song's DSD needs as DoP, from its format as the library words it ("DSD64", "DSD128 · 5.1"):
    /// 176.4 kHz for DSD64. nil for a song that isn't DSD.
    public static func carrier(format: String) -> Double? {
        let text = format.uppercased()
        guard text.hasPrefix("DSD") else { return nil }
        let multiple = Int(text.dropFirst(3).prefix { $0.isNumber }) ?? 64
        return Double(multiple) * 44_100 / 16
    }

    /// Why DSD is asked for as PCM on this output right now; nil when it is asked for as DoP. `carrier`: the rate the
    /// song's DSD needs, when known. Says the same as `ceiling`: nil exactly when `ceiling` allows the song.
    public static func reason(route: PhoneRoute?, volume: Double?, dacs: DoPDACs, carrier: Double? = nil) -> PCMReason? {
        guard canTest(route) else { return .notADAC }
        switch dacs.answer(for: route?.uid) {
        case nil: return .notTested
        case .hiss?: return .failedTest
        case .music?: break
        }
        guard dacs.volumeIsOutOfTheWay(volume, for: route?.uid) else { return .volume }
        guard let top = dacs.ceiling(for: route?.uid) else { return .rate }
        if let carrier, carrier > top + 0.5 { return .rate }
        return nil
    }

    /// Where the level of what the DAC plays is set, as far as anything shows.
    public enum Level: String, Equatable, Sendable {
        /// iOS's volume has been seen to move while this was the output: the phone's buttons set it.
        case phone
        /// This DAC played the DoP test's chord with iOS's volume at this level below the top: iOS's number changes
        /// nothing it gets, so its volume is set on the DAC.
        case dac
        /// Nothing says either way. iOS has no API that tells an app whether an output's volume is fixed.
        case unknown
    }

    public static func level(_ output: OutputState, dacs: DoPDACs) -> Level {
        if dacs.heardBelowTop(at: output.volume, for: output.route?.uid) { return .dac }
        return output.volumeMoved ? .phone : .unknown
    }

    /// "DSD128 (384 kHz carrier)" parts for a carrier rate: the DSD it holds, named the way a DAC's display names it.
    public static func name(carrier: Double) -> String { name(dsdRate: carrier * 16) }

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

/// The sound the DoP test plays: five seconds of DSD made here (nothing to ship), a soft three-note chord that rises from
/// silence, already packed as DoP frames. It is DSD64 for the first carrier rate and the same chord at the DSD rate each
/// other carrier holds (16 DSD bits a frame: 192 kHz is DSD64 of the 48 kHz family, 352.8 and 384 kHz are DSD128). A DAC that decodes DoP plays the chord. One that doesn't plays the frames as 24-bit
/// PCM: the marker alternates at 88.2 kHz, far above hearing, and the DSD bits sit in the low 16 bits, 42 dB or more under
/// full scale, so the worst case is a quiet hiss. The same recipe as the Mac's test (`DoPTestClip`).
public enum DoPProbeClip {
    public static let dsdRate = 2_822_400
    public static let carrierRate = 176_400.0
    public static let seconds = 5.0
    /// DSD silence sent as DoP before the chord, so a DAC has locked on to DSD (and unmuted) by the time the chord
    /// starts: a DAC that takes a moment to switch would otherwise swallow the quiet start, or all of it.
    public static let leadIn = 1.0
    /// DSD silence: as many ones as zeros in every byte.
    public static let idle: UInt8 = 0x69
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
    public static func dsd(rate dsdRate: Int = DoPProbeClip.dsdRate) -> [UInt8] {
        let samples = Int(seconds * Double(dsdRate))
        var bytes = [UInt8](repeating: 0, count: (samples + 15) / 16 * 2)
        // The signal changes every 64 DSD samples (44.1 kHz or faster) and is drawn straight between: plenty for a chord under 1 kHz.
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
        for index in whole..<bytes.count { bytes[index] = idle }
        return bytes
    }

    /// One 24-bit DoP word: the marker (0x05, then 0xFA, alternating by frame), then 16 DSD bits, oldest first.
    public static func word(frame: Int, _ first: UInt8, _ second: UInt8) -> UInt32 {
        (frame & 1 == 0 ? 0x05 : 0xFA) << 16 | UInt32(first) << 8 | UInt32(second)
    }

    /// How many frames of DSD silence come before the chord at `carrier`: an even number, so the chord's first frame
    /// carries the marker a clip without the lead-in starts with.
    public static func leadFrames(carrier: Double = DoPProbeClip.carrierRate) -> Int {
        Int((carrier * leadIn / 2).rounded()) * 2
    }

    /// The chord alone as DoP frames for `carrier`, one word a frame, numbered from `first` (which decides the marker).
    public static func chord(carrier: Double = DoPProbeClip.carrierRate, first: Int = 0) -> [UInt32] {
        let bits = dsd(rate: Int(carrier.rounded()) * 16)
        return (0..<bits.count / 2).map { word(frame: first + $0, bits[2 * $0], bits[2 * $0 + 1]) }
    }

    /// The clip as DoP frames for `carrier`, one word a frame (both channels carry the same): the lead-in of DSD silence,
    /// then the chord. Valid DoP from its first frame: the marker alternates all the way through.
    public static func frames(carrier: Double = DoPProbeClip.carrierRate) -> [UInt32] {
        let lead = leadFrames(carrier: carrier)
        return (0..<lead).map { word(frame: $0, idle, idle) } + chord(carrier: carrier, first: lead)
    }

    /// A DoP word as the float sample that an output turns back into exactly that 24-bit word.
    public static func sample(_ word: UInt32) -> Float {
        Float(Int32(bitPattern: word << 8)) / 2_147_483_648
    }
}
