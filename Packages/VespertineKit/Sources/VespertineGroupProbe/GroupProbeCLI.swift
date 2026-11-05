//
// Vespertine — Phase 0 speaker-group probe: the command-line front of group-info, group-play and group-skew.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

public enum GroupProbeCLI {
    public static let commands: Set<String> = ["group-info"]

    public static let usage = """
        vespertine-probe group-info <leader> [<follower> …] [--json]
            Read-only report on output devices (names or UIDs): clock domains, rates, reported latency and safety offset,
            hog owners, and which followers a private aggregate would have to drift-correct. The first device is the clock leader.
        """

    /// Runs one of `commands`; returns the process exit code (0 ok, 1 a finding that stops a group, 2 bad arguments).
    public static func run(_ command: String, _ arguments: [String]) -> Int32 {
        switch command {
        case "group-info": return groupInfo(arguments)
        default: print(usage); return 2
        }
    }

    /// Devices named on the command line, in order; nil (after printing why) when one can't be resolved.
    static func resolve(_ names: [String], in devices: [OutputDevice]) -> [OutputDevice]? {
        var out: [OutputDevice] = []
        let candidates = devices.map { (uid: $0.uid, name: $0.name) }
        for name in names {
            switch DeviceMatcher.resolve(name, in: candidates) {
            case .found(let i): out.append(devices[i])
            case .notFound: print("no output device matching \u{201C}\(name)\u{201D}"); return nil
            case .ambiguous(let ix):
                print("\u{201C}\(name)\u{201D} matches \(ix.map { devices[$0].name }.joined(separator: ", ")); use the exact name or the UID")
                return nil
            }
        }
        return out
    }

    static func groupInfo(_ arguments: [String]) -> Int32 {
        let json = arguments.contains("--json")
        let names = arguments.filter { !$0.hasPrefix("--") }
        guard !names.isEmpty else { print(usage); return 2 }
        guard let devices = resolve(names, in: OutputDevices.list()) else { return 2 }
        let uids = devices.map(\.uid)
        guard Set(uids).count == uids.count else { print("the same device is named twice"); return 2 }
        let report = GroupInfo.analyse(devices.map(MemberInfo.read))
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(report) { print(String(decoding: data, as: UTF8.self)) }
        } else {
            print(report.text)
        }
        return report.canGroup ? 0 : 1
    }
}
