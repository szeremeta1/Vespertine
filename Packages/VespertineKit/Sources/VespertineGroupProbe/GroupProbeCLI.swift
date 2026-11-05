//
// Vespertine — Phase 0 speaker-group probe: the command-line front of group-info, group-play and group-skew.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

public enum GroupProbeCLI {
    public static let commands: Set<String> = ["group-info", "group-play"]

    public static let usage = """
        vespertine-probe group-info <leader> [<follower> …] [--json]
            Read-only report on output devices (names or UIDs): clock domains, rates, reported latency and safety offset,
            hog owners, and which followers a private aggregate would have to drift-correct. The first device is the clock leader.

        vespertine-probe group-play <leader> <follower>[,<follower>…] [options] <file>…        (dev only; needs VESPERTINE_GROUP_PROBE=1)
            Builds a private aggregate of the devices (leader first), sets and reads back every member's own rate, plays the files
            through the real engine to it, and reports what the engine claims against what each member reports. Nothing is saved;
            the aggregate is gone on exit and rates are put back.
            --seconds N        play each file for N seconds (default 5)
            --rate Hz          force the group rate (default: the first file's rate if every device offers it)
            --no-drift         turn drift correction off on every follower (an experiment: it then slips instead)
            --quality N        drift-correction quality 0…127 (default 127)
            --exclusive-members  hold every member exclusively (hog) while playing
            --real-hardware    allow real outputs (the default refuses anything but virtual devices)
            --json             print the report as JSON
        """

    /// Runs one of `commands`; returns the process exit code (0 ok, 1 a finding that stops a group, 2 bad arguments).
    public static func run(_ command: String, _ arguments: [String]) -> Int32 {
        switch command {
        case "group-info": return groupInfo(arguments)
        case "group-play": return groupPlay(arguments)
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

    static func groupPlay(_ arguments: [String]) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        var rest = arguments, flags: Set<String> = [], values: [String: String] = [:]
        let withValue: Set<String> = ["--seconds", "--rate", "--quality"]
        var positional: [String] = []
        while !rest.isEmpty {
            let a = rest.removeFirst()
            if withValue.contains(a) { guard !rest.isEmpty else { print("\(a) needs a value"); return 2 }; values[a] = rest.removeFirst() }
            else if a.hasPrefix("--") { flags.insert(a) }
            else { positional.append(a) }
        }
        guard positional.count >= 3 else { print(usage); return 2 }
        let names = [positional[0]] + positional[1].split(separator: ",").map(String.init)
        let files = positional.dropFirst(2).map { URL(fileURLWithPath: $0) }
        let all = OutputDevices.list()
        guard let devices = resolve(names, in: all) else { return 2 }
        if let why = GroupPlayGate.refusal(devices: devices.map { .init(name: $0.name, uid: $0.uid, transport: $0.transport) },
                                           realHardwareAllowed: flags.contains("--real-hardware"), environment: ProcessInfo.processInfo.environment,
                                           inUseByOthers: { c in all.first { $0.uid == c.uid }.map { LoopbackGuard.inUseByOthers($0.id) } ?? false }) {
            print(why); return 2
        }
        for f in files where !FileManager.default.fileExists(atPath: f.path) { print("no such file: \(f.path)"); return 2 }
        let report = GroupAnalysisGate.blockers(devices.map(MemberInfo.read))
        if !report.isEmpty { print(report.joined(separator: "\n")); return 1 }
        var config = GroupPlayConfig(devices: devices, files: Array(files))
        if let s = values["--seconds"].flatMap(Double.init) { config.seconds = s }
        config.rate = values["--rate"].flatMap(Double.init).map { $0 < 1_000 ? $0 * 1_000 : $0 }
        if let q = values["--quality"].flatMap(Int.init) { config.quality = max(0, min(127, q)) }
        if flags.contains("--no-drift") { config.drift = .off }
        config.exclusiveMembers = flags.contains("--exclusive-members")
        let json = flags.contains("--json")
        if json { config.log = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) } }
        do {
            let result = try GroupPlay.run(config)
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                if let data = try? encoder.encode(result) { print(String(decoding: data, as: UTF8.self)) }
            } else {
                print(result.text)
            }
            let played = result.files.allSatisfy(\.played)
            return played && result.restoredAllRates && result.aggregateGoneAfter ? 0 : 1
        } catch {
            print("group-play failed: \(error)")
            return 1
        }
    }
}

enum GroupAnalysisGate {
    /// Blockers from group-info's analysis, as lines to print; empty when the group can be built.
    static func blockers(_ infos: [MemberInfo]) -> [String] {
        GroupInfo.analyse(infos).findings.filter { $0.severity == .blocker }.map { "BLOCKER: \($0.text)" }
    }
}
