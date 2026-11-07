//
// Vespertine — speaker groups: which speaker plays which channel of a song, from where the speakers really stand.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The rule generalizes what BedRouter does for a speaker setup and keeps the ITU-R BS.775 folds as special cases:
//   1. A channel whose speaker the group has plays on it alone, at 1.0.
//   2. Else, on the nearest single speaker no other channel claimed (Ls on a back pair), alone, at 1.0.
//   3. Else it is panned between the two speakers on either side of its angle, with equal power (the tangent law of 2-D
//      vector-base panning). Halfway between two is 0.707 on each, which is the ITU's −3 dB (a 5.1 centre on L and R).
//   4. A channel outside every pair's arc goes to the nearest speaker alone, at −3 dB.
//   Ceiling channels a group has no ceiling speaker for are folded to the ear-level speakers under them, at −3 dB.
//   The LFE plays on the group's subwoofer, or follows the LFE policy.
// The angles are the ones drawn in the room, seen from where the listener faces. Rows of the matrix are the aggregate's
// channels, in the members' order. Nothing here touches playback yet.
//

import CoreAudio
import Foundation

public struct PositionRouter: Equatable, Sendable {
    /// The ITU −3 dB.
    public static let foldGain = Float(0.5.squareRoot())

    /// How a channel reached its speaker.
    public enum Kind: Equatable, Sendable {
        /// The speaker of its own place, alone at 1.0.
        case own
        /// The nearest single speaker, alone at 1.0.
        case placed
        /// Panned between two speakers, equal power.
        case panned
        /// Folded onto the nearest speaker or the ones under it, at −3 dB.
        case folded
        /// The LFE, by the group's LFE policy.
        case lfe
    }

    public struct Route: Equatable, Sendable {
        /// The aggregate channel it plays on.
        public var output: Int
        public var gain: Float
        public var kind: Kind
    }

    /// One source channel's gain into an output channel.
    public struct Tap: Equatable, Sendable {
        public var source: Int
        public var gain: Float
    }

    public let sourceChannels: Int
    /// The aggregate's channels: what the group's members offer, used or not.
    public let outputChannels: Int
    /// For each source channel, where it plays. Empty: it is heard nowhere.
    public let routes: [[Route]]
    private let rows: [[Tap]]

    /// nil when there is nothing to play (no channels) or nowhere to play it (no speaker wired to an output).
    public init?(source labels: [AudioChannelLabel], group: SpeakerGroup) {
        let outputOf = group.aggregateChannels
        guard !labels.isEmpty, !outputOf.isEmpty else { return nil }
        let sourceLabels = ChannelLayouts.normalizedSurrounds(labels)
        let roles = sourceLabels.map { SpeakerRole(label: $0) }
        let present = Set(roles.compactMap { $0 })

        // Where the ear-level speakers stand, by angle: what channels are panned across.
        let targets: [(azimuth: Double, output: Int)] = group.speakers.compactMap { speaker in
            guard !speaker.role.isHeight, speaker.role != .lfe, let output = outputOf[speaker.role], speaker.position.isFinite,
                  SpeakerGeometry.distance(from: group.listener, to: speaker.position) > 0 else { return nil }
            return (SpeakerGeometry.azimuth(from: group.listener, to: speaker.position), output)
        }.sorted { $0.azimuth < $1.azimuth }

        var found = [[Route]](repeating: [], count: labels.count)
        var claimed = Set<Int>()
        // 1. Its own speaker.
        for (s, role) in roles.enumerated() {
            guard let role, let output = outputOf[role] else { continue }
            found[s] = [Route(output: output, gain: 1, kind: .own)]
            claimed.insert(output)
        }
        for (s, role) in roles.enumerated() where found[s].isEmpty {
            guard let role else { continue }
            // The LFE has no place to be panned to: the group's policy decides.
            if role == .lfe {
                found[s] = Self.lfeRoutes(group.lfePolicy, group: group, outputOf: outputOf)
                continue
            }
            // 2. The nearest single speaker nobody else has.
            let wanted = ChannelLayouts.nearest(sourceLabels[s]).filter { $0.count == 1 }.compactMap { SpeakerRole(label: $0[0]) }
                .filter { $0.isHeight == role.isHeight }
            if let output = wanted.lazy.compactMap({ outputOf[$0] }).first(where: { !claimed.contains($0) }) {
                found[s] = [Route(output: output, gain: 1, kind: .placed)]
                claimed.insert(output)
                continue
            }
            // 3 and 4. By angle.
            found[s] = Self.byAngle(Self.azimuth(of: role, among: present), height: role.isHeight, targets: targets)
        }

        sourceChannels = labels.count
        outputChannels = group.totalChannels
        routes = found
        var rows = [[Tap]](repeating: [], count: group.totalChannels)
        for (s, list) in found.enumerated() {
            for route in list where route.output < rows.count { rows[route.output].append(Tap(source: s, gain: route.gain)) }
        }
        self.rows = rows
    }

    // MARK: What it makes of the song

    /// Source channels heard nowhere (the LFE under the "drop" policy, a channel with no speaker's name).
    public var dropped: [Int] { routes.indices.filter { routes[$0].isEmpty } }

    /// Every channel plays alone, at 1.0, on a speaker of its own: nothing is mixed, panned or folded. (Channels heard nowhere
    /// are listed in `dropped`.)
    public var isUnmixed: Bool {
        routes.allSatisfy { list in list.allSatisfy { ($0.kind == .own || $0.kind == .placed) && $0.gain == 1 } && list.count <= 1 }
            && rows.allSatisfy { $0.count <= 1 }
    }

    /// The output channels that carry exactly one source channel at exactly 1.0: the samples the file holds, nothing added.
    public var untouchedOutputs: [Int] {
        rows.indices.filter { rows[$0].count == 1 && rows[$0][0].gain == 1 }
    }

    /// What output channel `output` is made of: the source channels and gains summed into it.
    public func matrixRow(_ output: Int) -> [Tap] { rows.indices.contains(output) ? rows[output] : [] }

    /// The largest sum of gains any output channel adds up (when every channel peaks at once at full scale): the headroom the
    /// shared preamp must leave. 1 when nothing is mixed.
    public var worstCaseGain: Float { rows.map { $0.reduce(Float(0)) { $0 + abs($1.gain) } }.max() ?? 0 }

    /// Interleaved source frames to interleaved output frames (`outputChannels` wide). An output with a single channel at 1.0 is
    /// copied, so its samples stay the file's to the bit.
    public func route(_ input: UnsafePointer<Float>, into output: UnsafeMutablePointer<Float>, frames: Int) {
        for (o, taps) in rows.enumerated() {
            if taps.isEmpty {
                for f in 0..<frames { output[f * outputChannels + o] = 0 }
            } else if taps.count == 1, taps[0].gain == 1 {
                let s = taps[0].source
                for f in 0..<frames { output[f * outputChannels + o] = input[f * sourceChannels + s] }
            } else {
                for f in 0..<frames {
                    var sum: Float = 0
                    for tap in taps { sum += input[f * sourceChannels + tap.source] * tap.gain }
                    output[f * outputChannels + o] = sum
                }
            }
        }
    }

    // MARK: Pieces

    /// The angle a channel stands at in its own layout, from straight ahead, positive to the right. A lone surround pair is at
    /// ±110° (5.1, whichever name it goes by); with a pair of sides and a pair of backs the sides are at ±90° and the backs ±135°.
    static func azimuth(of role: SpeakerRole, among present: Set<SpeakerRole>) -> Double {
        let hasSides = present.contains(.sideLeft) || present.contains(.sideRight)
        let hasBacks = present.contains(.backLeft) || present.contains(.backRight)
        let both = hasSides && hasBacks
        switch role {
        case .sideLeft where !both, .backLeft where !both: return -110
        case .sideRight where !both, .backRight where !both: return 110
        default: return role.defaultAzimuth ?? 0
        }
    }

    private static func lfeRoutes(_ policy: LFEPolicy, group: SpeakerGroup, outputOf: [SpeakerRole: Int]) -> [Route] {
        switch policy {
        case .drop:
            return []
        case .toAll(let dB):
            guard dB.isFinite else { return [] }
            let gain = Float(pow(10, dB / 20))
            return group.speakers.compactMap { outputOf[$0.role] }.sorted().map { Route(output: $0, gain: gain, kind: .lfe) }
        case .toSpeaker(let id):
            guard let role = group.speakers.first(where: { $0.id == id })?.role, let output = outputOf[role] else { return [] }
            return [Route(output: output, gain: 1, kind: .lfe)]
        }
    }

    /// Steps 3 and 4: the speakers on either side of the angle, with equal power; else the nearest one at −3 dB. A ceiling
    /// channel is folded: −3 dB on top of its pan.
    private static func byAngle(_ angle: Double, height: Bool, targets: [(azimuth: Double, output: Int)]) -> [Route] {
        guard !targets.isEmpty else { return [] }
        let fold = height ? foldGain : 1
        let n = targets.count
        for i in 0..<n {
            let a1 = targets[i].azimuth
            let a2 = i + 1 < n ? targets[i + 1].azimuth : targets[0].azimuth + 360
            let gap = a2 - a1
            // Coincident speakers have no arc, and a gap of 180° or more has no pair that can place a sound inside it.
            guard gap > 1e-9, gap < 180 - 1e-9 else { continue }
            guard let at = [angle, angle + 360].first(where: { $0 >= a1 - 1e-6 && $0 <= a2 + 1e-6 }) else { continue }
            if abs(at - a1) < 1e-6 { return [Route(output: targets[i].output, gain: fold, kind: height ? .folded : .placed)] }
            if abs(at - a2) < 1e-6 { return [Route(output: targets[(i + 1) % n].output, gain: fold, kind: height ? .folded : .placed)] }
            // Tangent law: (g2 − g1) / (g2 + g1) = tan(offset from the arc's middle) / tan(half the gap).
            let t = tan((at - (a1 + a2) / 2) * .pi / 180) / tan(gap / 2 * .pi / 180)
            let norm = (Double(2) * (1 + t * t)).squareRoot()
            let (g1, g2) = (Float((1 - t) / norm) * fold, Float((1 + t) / norm) * fold)
            return [Route(output: targets[i].output, gain: g1, kind: height ? .folded : .panned),
                    Route(output: targets[(i + 1) % n].output, gain: g2, kind: height ? .folded : .panned)]
        }
        let nearest = targets.enumerated().min { distance($0.element.azimuth, angle) < distance($1.element.azimuth, angle) }!.element
        return [Route(output: nearest.output, gain: distance(nearest.azimuth, angle) < 1e-6 ? 1 : foldGain, kind: .folded)]
    }

    /// The angle between two directions, 0…180.
    private static func distance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }
}
