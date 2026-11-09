//
// Vespertine: speaker groups in the output list: a row for each saved group saying whether it can play and what it is made of or
// what is missing, and the lines of the signal path for its DACs. Plain data; the lists are a thin layer.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum GroupOutputRows {
    public struct Row: Equatable, Sendable, Identifiable {
        /// What the engine chooses the group by (`SpeakerGroup.outputUID`).
        public var uid: String
        public var name: String
        /// All its outputs are connected and it is valid.
        public var isReady: Bool
        /// Uppercase, like the other rows of the list: what it is made of, or what is missing.
        public var detail: String
        public var id: String { uid }
    }

    public static func rows(groups: [SpeakerGroup], devices: [OutputDevice]) -> [Row] {
        groups.map { group in
            switch GroupOutput.resolve(group, among: devices) {
            case .ready(let output, _):
                let names = group.members.map { $0.name.uppercased() }.joined(separator: " + ")
                return Row(uid: group.outputUID, name: group.name, isReady: true,
                           detail: "SPEAKER GROUP · \(output.capabilities.outputChannels) CH · \(names)")
            case .missing(let names):
                return Row(uid: group.outputUID, name: group.name, isReady: false,
                           detail: "NOT CONNECTED · \(names.map { $0.uppercased() }.joined(separator: ", ")) MISSING")
            case .noCommonRate:
                return Row(uid: group.outputUID, name: group.name, isReady: false, detail: "NEEDS ATTENTION · THE OUTPUTS SHARE NO SAMPLE RATE")
            case .invalid, .single:
                let why = group.issues.first?.description.uppercased() ?? "THE GROUP'S SETTINGS"
                return Row(uid: group.outputUID, name: group.name, isReady: false, detail: "NEEDS ATTENTION · \(why)")
            }
        }
    }

    public struct Line: Equatable, Sendable {
        public var title: String
        public var detail: String
        public var value: String
        /// The DAC's part of the song reaches it untouched (not resampled, format confirmed and holding the song).
        public var isUntouched: Bool
    }

    /// One line per DAC for the Inspector: the speakers it plays, its place in the clock, and whether it is bit-perfect or resampled.
    public static func signalPathLines(_ path: GroupSignalPath) -> [Line] {
        path.members.map { m in
            let untouched = path.isUntouched(m)
            var parts: [String] = []
            if m.isUsed { parts.append(m.speakers.map(\.rawValue).joined(separator: " ")) } else { parts.append("not used by this song") }
            if m.isLeader { parts.append("clock leader") }
            else if m.resampled { parts.append("follows \(path.leaderName), resampled to stay in step") }
            else { parts.append("shares \(path.leaderName)'s clock") }
            return Line(title: m.name, detail: parts.joined(separator: " · "),
                        value: m.resampled ? "resampled" : (untouched ? "bit-perfect" : "converted"), isUntouched: untouched)
        }
    }
}
