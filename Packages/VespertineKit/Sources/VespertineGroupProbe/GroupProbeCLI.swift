//
// Vespertine — Phase 0 speaker-group probe: the command-line front of group-info, group-play and group-skew.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import VespertineAudio

public enum GroupProbeCLI {
    public static let commands: Set<String> = ["group-info", "group-play", "group-skew"]

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

        vespertine-probe group-skew <leader> <follower> --mic <input device> [options]        (dev only; needs VESPERTINE_GROUP_PROBE=1)
            Plays a timing chirp from the leader (twice) and from the follower (once, between them) through a private aggregate and
            records them with one microphone (the UMIK-1), N times, each capture starting the output afresh. Reports the follower's
            arrival against the leader's, in frames and µs, and its spread across restarts (H3), and across times since the output
            started with several --lead-in values (H4). The mean includes the speakers' acoustic path difference; the spread is the
            start skew. Plays at low level (-20 dBFS) unless --level says otherwise, on real outputs only with --real-hardware.
            --mic NAME         input device (name or UID); needed unless --control is used with a single device
            --runs N           captures per lead-in (default 8)
            --lead-in S[,S…]   seconds before the first reference (default 1.5); the follower chirp comes about a second later
            --pause S          seconds between captures (default 1)
            --level L          peak level of the chirps, 0…1 (default 0.1)
            --leader-channel K / --follower-channel K   output channels in the group (default: the leader's first, the follower's first)
            --input-channel K  microphone channel (default 0)
            --rate Hz          group rate (default: the microphone's rate if every device offers it)
            --span S           each capture lasts about S seconds (a second chirp from the follower at the end), and reports the
                               follower's slip against the leader in ppm: the DACs' drift (H2); use with --no-drift
            --no-drift         build the aggregate with drift correction off (so the DACs run free and slip)
            --keep DIR         save each run's raw microphone capture as DIR/run-N.wav (32-bit float, mono), failed runs too,
                               so an outlier or a "reference not found" can be looked at afterwards
            --control          every chirp from the leader alone: the method's own zero and spread (one device is enough)
            --exclusive-members  hold every member exclusively while measuring
            --real-hardware    allow real outputs
            --json             print the report as JSON
        """

    /// Runs one of `commands`; returns the process exit code (0 ok, 1 a finding that stops a group, 2 bad arguments).
    public static func run(_ command: String, _ arguments: [String]) -> Int32 {
        switch command {
        case "group-info": return groupInfo(arguments)
        case "group-play": return groupPlay(arguments)
        case "group-skew": return groupSkew(arguments)
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

// MARK: - group-skew

final class AsyncResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?
    func set(_ v: Result<T, Error>) { lock.lock(); value = v; lock.unlock() }
    func get() -> Result<T, Error>? { lock.lock(); defer { lock.unlock() }; return value }
}

extension GroupProbeCLI {
    static func groupSkew(_ arguments: [String]) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        var rest = arguments, flags: Set<String> = [], values: [String: String] = [:], positional: [String] = []
        let withValue: Set<String> = ["--mic", "--runs", "--lead-in", "--pause", "--level", "--leader-channel", "--follower-channel", "--input-channel", "--rate", "--span", "--keep"]
        while !rest.isEmpty {
            let a = rest.removeFirst()
            if withValue.contains(a) { guard !rest.isEmpty else { print("\(a) needs a value"); return 2 }; values[a] = rest.removeFirst() }
            else if a.hasPrefix("--") { flags.insert(a) }
            else { positional.append(a) }
        }
        let control = flags.contains("--control")
        guard positional.count == 2 || (control && positional.count == 1) else { print(usage); return 2 }
        let all = OutputDevices.list()
        guard let devices = resolve(positional, in: all) else { return 2 }
        let direct = devices.count == 1
        let environment = ProcessInfo.processInfo.environment
        if let why = GroupPlayGate.refusal(devices: devices.map { .init(name: $0.name, uid: $0.uid, transport: $0.transport) } + (direct ? [.init(name: "-", uid: "-", transport: .virtual)] : []),
                                           realHardwareAllowed: flags.contains("--real-hardware"), environment: environment,
                                           inUseByOthers: { c in all.first { $0.uid == c.uid }.map { LoopbackGuard.inUseByOthers($0.id) } ?? false }) {
            print(why); return 2
        }
        let micName = values["--mic"] ?? (direct ? devices[0].name : nil)
        guard let micName else { print("--mic <input device> is needed"); return 2 }
        guard let mic = RoomDeviceDirectory.inputDevice(named: micName) else { print("no input device matching \u{201C}\(micName)\u{201D}"); return 2 }
        let blockers = GroupAnalysisGate.blockers(devices.map(MemberInfo.read))
        if !blockers.isEmpty { print(blockers.joined(separator: "\n")); return 1 }

        let rate = values["--rate"].flatMap(Double.init).map { $0 < 1_000 ? $0 * 1_000 : $0 } ?? mic.nominalRate
        guard devices.allSatisfy({ $0.capabilities.sampleRates.contains { abs($0 - rate) < 0.5 } }) else {
            print("not every device offers \(SampleRate.format(rate)) kHz (the microphone's rate); pass --rate"); return 2
        }
        let found = devices.map { ProbeHAL.nominalRate($0.id) }
        var hogged: [AudioObjectID] = []
        var aggregate: PrivateAggregate?
        func restore() {
            for id in hogged { ProbeHAL.releaseHog(id) }
            hogged = []
            aggregate?.destroy(); aggregate = nil
            for (d, r) in zip(devices, found) { ProbeHAL.setNominalRate(r, on: d.id) }
        }
        defer { restore() }
        for d in devices {
            let now = ProbeHAL.setNominalRate(rate, on: d.id)
            print("\(d.name): member reads \(SampleRate.format(now))k")
            guard abs(now - rate) < 0.5 else { print("\(d.name) did not take \(SampleRate.format(rate)) kHz"); return 1 }
        }
        if flags.contains("--exclusive-members") {
            for d in devices { if ProbeHAL.acquireHog(d.id) { hogged.append(d.id) } else { print("warning: \(d.name) could not be taken exclusively") } }
        }
        let output: AudioObjectID
        var followerDefault = 0
        if direct {
            output = devices[0].id
        } else {
            let infos = devices.map(MemberInfo.read)
            do {
                let made = try PrivateAggregate.create(members: infos.map { .init(uid: $0.uid, clockDomain: $0.clockDomain) }, name: "Vespertine group skew",
                                                       drift: flags.contains("--no-drift") ? .off : .byClockDomain)
                aggregate = made; output = made.id
            } catch { print("group-skew failed: \(error)"); return 1 }
            followerDefault = infos[0].outputChannels
            Thread.sleep(forTimeInterval: 0.5)
        }
        var config = GroupSkewConfig(inputDevice: mic.id, outputDevice: output, leaderChannel: values["--leader-channel"].flatMap(Int.init) ?? 0,
                                     followerChannel: values["--follower-channel"].flatMap(Int.init) ?? followerDefault, rate: rate)
        config.inputChannel = values["--input-channel"].flatMap(Int.init) ?? 0
        config.runsPerLeadIn = values["--runs"].flatMap(Int.init) ?? 8
        config.leadIns = values["--lead-in"].map { $0.split(separator: ",").compactMap { Double($0) } } ?? [1.5]
        config.pauseSeconds = values["--pause"].flatMap(Double.init) ?? 1
        config.level = max(0.001, min(1, values["--level"].flatMap(Double.init) ?? 0.1))
        config.control = control
        config.spanSeconds = values["--span"].flatMap(Double.init).map { max(2, $0) }
        config.keepDirectory = values["--keep"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        let json = flags.contains("--json")
        let say: (String) -> Void = { json ? FileHandle.standardError.write(Data(($0 + "\n").utf8)) : print($0) }
        say("group-skew: \(devices.map(\.name).joined(separator: " + ")) → \(mic.name) channel \(config.inputChannel) at \(SampleRate.format(rate))k, \(config.runsPerLeadIn) runs × lead-ins \(config.leadIns)")

        let box = AsyncResult<GroupSkewReport>()
        let captured = config
        Task {
            do { box.set(.success(try await GroupSkewRunner.run(captured, makeDevice: { CoreAudioRoomDevice() }, permission: SystemMicrophonePermission(), progress: say))) }
            catch { box.set(.failure(error)) }
        }
        while box.get() == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        switch box.get()! {
        case .failure(let error): print("group-skew failed: \(error.localizedDescription)"); return 1
        case .success(let report):
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                if let data = try? encoder.encode(report) { print(String(decoding: data, as: UTF8.self)) }
            } else {
                print(report.text)
            }
            return report.runs.isEmpty ? 1 : 0
        }
    }
}
