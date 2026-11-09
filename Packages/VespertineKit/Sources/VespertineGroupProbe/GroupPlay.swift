//
// Vespertine: Phase 0 of multi-DAC speaker groups, PR 0.2: `vespertine-probe group-play`. Builds a private aggregate of
// the named devices (the first is the clock leader), sets and reads back every member's own rate, plays files through the
// real engine to the aggregate, and reports what the engine claims against what Core Audio says for each member.
// Dev only: nothing here is in the app, the group is not saved, and the aggregate is gone when the command exits.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import VespertineAudio

/// Why a group-play must not run, decided before anything is touched.
public enum GroupPlayGate {
    public static let environmentVariable = "VESPERTINE_GROUP_PROBE"

    /// nil when it may run. Real outputs need `--real-hardware` (a speaker or DAC makes sound); a virtual device that
    /// another process is using is left alone; the dev-only variable must be set.
    public struct Candidate: Equatable, Sendable {
        public var name: String
        public var uid: String
        public var transport: Transport
        public init(name: String, uid: String, transport: Transport) { self.name = name; self.uid = uid; self.transport = transport }
    }

    public static func refusal(devices: [Candidate], realHardwareAllowed: Bool, environment: [String: String],
                               inUseByOthers: (Candidate) -> Bool) -> String? {
        guard environment[environmentVariable] == "1" else {
            return "group-play is a development probe: set \(environmentVariable)=1 to run it."
        }
        guard devices.count >= 2 else { return "group-play needs a leader and at least one follower." }
        guard Set(devices.map(\.uid)).count == devices.count else { return "the same device is named twice." }
        let real = devices.filter { $0.transport != .virtual }
        if !real.isEmpty && !realHardwareAllowed {
            return "\(real.map(\.name).joined(separator: ", ")) \(real.count == 1 ? "is a real output" : "are real outputs"): group-play makes sound on them. Pass --real-hardware to allow it (keep the volume low)."
        }
        if let busy = devices.first(where: { $0.transport == .virtual && inUseByOthers($0) }) {
            return "another process is using \(busy.name); it is left alone."
        }
        if let aggregate = devices.first(where: { $0.transport == .aggregate }) {
            return "\(aggregate.name) is an aggregate; groups can't nest."
        }
        return nil
    }
}

public struct GroupPlayConfig {
    public var devices: [OutputDevice]
    public var files: [URL]
    public var seconds: Double = 5
    public var rate: Double?
    public var drift: GroupAggregate.DriftMode = .byClockDomain
    public var quality: Int = Int(kAudioAggregateDriftCompensationMaxQuality)
    public var exclusiveMembers = false
    /// Called about every 10 ms while waiting, on the calling thread (a test drains its recorders here).
    public var tick: (() -> Void)?
    public var log: (String) -> Void = { print($0) }

    public init(devices: [OutputDevice], files: [URL]) { self.devices = devices; self.files = files }
}

public struct GroupPlayReport: Codable, Equatable, Sendable {
    public struct MemberRow: Codable, Equatable, Sendable {
        public var name: String
        public var uid: String
        public var rateFound: Double
        public var rateRequested: Double
        /// Read from the member itself, not from the aggregate (the aggregate's streams don't tell the truth about its members).
        public var rateDuringPlay: Double
        public var physicalFormatDuringPlay: String
        public var hogPIDDuringPlay: Int32
        public var driftCompensation: Bool
        public var driftQuality: Int
        public var firstChannel: Int
        public var channels: Int
        public var rateAfter: Double
        public var hogPIDAfter: Int32
    }
    public struct FileRow: Codable, Equatable, Sendable {
        public var file: String
        public var sourceChannels: Int
        public var sourceRate: Double
        public var played: Bool
        public var state: String
        public var error: String?
        public var statusLine: String?
        public var claimsBitPerfect: Bool
        public var planReason: String?
        public var appliedRate: Double?
        public var appliedChannels: Int?
        public var appliedStreams: Int?
        public var exclusive: Bool?
        public var channelNames: [String]
        public var underruns: Int
        public var positionSeconds: Double
    }

    public var aggregateUID: String
    public var aggregateStreams: Int
    public var aggregateRateDuringPlay: Double
    public var rate: Double
    public var rateIsSourceRate: Bool
    public var members: [MemberRow]
    public var files: [FileRow]
    /// Things that would make the badge or the setup untruthful, in plain words. Empty when nothing is off.
    public var truthWarnings: [String]
    public var aggregateGoneAfter: Bool
    public var restoredAllRates: Bool
}

public enum GroupPlay {
    static func physicalFormat(_ device: AudioObjectID) -> String {
        ProbeHAL.outputStreams(device).compactMap { stream -> String? in
            guard let f = ProbeHAL.get(stream, kAudioStreamPropertyPhysicalFormat, initial: AudioStreamBasicDescription()) else { return nil }
            return "\(f.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "float" : "int")\(f.mBitsPerChannel) \(f.mChannelsPerFrame)ch @ \(SampleRate.format(f.mSampleRate))k"
        }.joined(separator: " + ")
    }

    private static func pump(_ seconds: Double, tick: (() -> Void)?) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            tick?()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Runs the whole sequence and always tears down (stop, release hogs, destroy the aggregate, put the rates back).
    public static func run(_ config: GroupPlayConfig) throws -> GroupPlayReport {
        let devices = config.devices
        let log = config.log
        guard let firstFile = config.files.first else { throw GroupProbeError.message("no file to play") }
        let (firstFormat, _) = try SourceInspector.inspect(firstFile)
        let plan = config.rate.map { RatePlanner.Plan(rate: $0, exact: abs($0 - firstFormat.sampleRate) < 0.5) }
            ?? RatePlanner.choose(source: firstFormat.sampleRate, memberRates: devices.map { $0.capabilities.sampleRates })
        guard let plan else { throw GroupProbeError.message("the devices share no sample rate") }
        if let forced = config.rate, devices.contains(where: { !$0.capabilities.sampleRates.contains { abs($0 - forced) < 0.5 } }) {
            throw GroupProbeError.message("not every device offers \(SampleRate.format(forced)) kHz")
        }

        let found = devices.map { ProbeHAL.nominalRate($0.id) }
        var hogged: [AudioObjectID] = []
        var aggregate: PrivateAggregate?
        let engine = PlaybackEngine()
        var rows: [GroupPlayReport.MemberRow] = []
        var fileRows: [GroupPlayReport.FileRow] = []
        var warnings: [String] = []
        var aggregateRate = 0.0, aggregateStreams = 0
        var states: [PrivateAggregate.SubDeviceState] = []

        func teardown() {
            engine.stopAndWait()
            pump(0.4, tick: config.tick)
            for id in hogged { ProbeHAL.releaseHog(id) }
            hogged = []
            aggregate?.destroy()
        }
        defer { if aggregate != nil || !hogged.isEmpty { teardown() } }

        // Each member to the common rate, one at a time, each read back from the member itself.
        for (device, original) in zip(devices, found) {
            let now = ProbeHAL.setNominalRate(plan.rate, on: device.id)
            log("\(device.name): \(SampleRate.format(original))k → asked \(SampleRate.format(plan.rate))k, member reads \(SampleRate.format(now))k")
            if abs(now - plan.rate) > 0.5 {
                for (d, o) in zip(devices, found) { ProbeHAL.setNominalRate(o, on: d.id) }
                throw GroupProbeError.message("\(device.name) did not take \(SampleRate.format(plan.rate)) kHz (reads \(SampleRate.format(now)) kHz)")
            }
        }
        if config.exclusiveMembers {
            for device in devices {
                if ProbeHAL.acquireHog(device.id) { hogged.append(device.id) } else {
                    warnings.append("\(device.name) could not be taken exclusively (held by process \(ProbeHAL.hogOwner(device.id)))")
                }
            }
            log("exclusive access: \(hogged.count) of \(devices.count) members held")
        }

        let infos = devices.map(MemberInfo.read)
        let members = infos.map { GroupAggregate.Member(uid: $0.uid, clockDomain: $0.clockDomain) }
        let created = try PrivateAggregate.create(members: members, name: "Vespertine group probe", drift: config.drift, quality: config.quality)
        aggregate = created
        pump(0.5, tick: config.tick)
        guard let aggregateDevice = OutputDevices.list().first(where: { $0.uid == created.uid }) else { throw GroupProbeError.notVisible(created.uid) }
        aggregateStreams = ProbeHAL.outputStreams(created.id).count
        aggregateRate = ProbeHAL.nominalRate(created.id)
        states = created.subDeviceStates()
        log("aggregate \(created.uid): \(aggregateStreams) streams, \(aggregateDevice.capabilities.outputChannels) channels, \(SampleRate.format(aggregateRate))k")

        var settings = EngineSettings()
        settings.deviceUID = aggregateDevice.uid
        settings.deviceName = aggregateDevice.name
        // A private aggregate has no hog-mode property: asking for exclusive access would only fail. Members are held above.
        settings.exclusive = false
        settings.ratePolicies = [aggregateDevice.uid: .fixed(plan.rate)]
        settings.spatialModes = [aggregateDevice.uid: .off]
        settings.dopDeviceUIDs = []
        settings.bitstreamDeviceUIDs = []
        engine.update(settings: settings)

        var memberRowsDuring: [(rate: Double, format: String, hog: Int32)] = []
        for url in config.files {
            let item = PlayableItem(url: url)
            var row = GroupPlayReport.FileRow(file: url.lastPathComponent, sourceChannels: 0, sourceRate: 0, played: false, state: "", error: nil,
                                              statusLine: nil, claimsBitPerfect: false, planReason: nil, appliedRate: nil, appliedChannels: nil,
                                              appliedStreams: nil, exclusive: nil, channelNames: [], underruns: 0, positionSeconds: 0)
            if let (format, _) = try? SourceInspector.inspect(url) { row.sourceChannels = format.channels; row.sourceRate = format.sampleRate }
            engine.play(item)
            let start = Date()
            while Date().timeIntervalSince(start) < 8 {
                let s = engine.snapshot
                if s.item?.id == item.id, s.signalPath != nil, s.state == .playing, s.position > 0.05 { row.played = true; break }
                if s.lastError != nil, s.state == .stopped { break }
                config.tick?()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            pump(min(1.0, config.seconds / 3), tick: config.tick)
            memberRowsDuring = devices.map { (ProbeHAL.nominalRate($0.id), physicalFormat($0.id), ProbeHAL.hogOwner($0.id)) }
            states = created.subDeviceStates()
            let snap = engine.snapshot
            row.state = snap.state.rawValue
            row.error = snap.lastError
            if let path = snap.signalPath {
                row.statusLine = path.statusLine
                row.claimsBitPerfect = path.isBitPerfect
                row.planReason = path.plan.reason
                row.appliedRate = path.applied.sampleRate
                row.appliedChannels = path.applied.virtualChannels
                row.appliedStreams = path.applied.streamCount
                row.exclusive = path.applied.exclusive
                row.channelNames = path.applied.channelNames
            }
            pump(max(0, config.seconds - 1), tick: config.tick)
            let end = engine.snapshot
            row.underruns = end.underruns
            row.positionSeconds = end.position
            fileRows.append(row)
            log("\(row.file): \(row.sourceChannels) ch @ \(SampleRate.format(row.sourceRate))k → \(row.statusLine ?? "no signal path")\(row.claimsBitPerfect ? " (claims bit-perfect)" : "")")
        }

        for (i, device) in devices.enumerated() {
            let during: (rate: Double, format: String, hog: Int32) = i < memberRowsDuring.count ? memberRowsDuring[i] : (rate: 0, format: "", hog: -1)
            let state = states.first { $0.uid == device.uid } ?? (i < states.count ? states[i] : nil)
            rows.append(.init(name: device.name, uid: device.uid, rateFound: found[i], rateRequested: plan.rate, rateDuringPlay: during.rate,
                              physicalFormatDuringPlay: during.format, hogPIDDuringPlay: during.hog,
                              driftCompensation: state?.driftCompensation ?? false, driftQuality: state?.quality ?? 0,
                              firstChannel: infos[..<i].reduce(0) { $0 + $1.outputChannels }, channels: infos[i].outputChannels,
                              rateAfter: 0, hogPIDAfter: -1))
        }

        // Truth checks: what would make the setup or the badge lie.
        for row in rows where abs(row.rateDuringPlay - plan.rate) > 0.5 {
            warnings.append("\(row.name) runs at \(SampleRate.format(row.rateDuringPlay)) kHz, not the planned \(SampleRate.format(plan.rate)) kHz (the aggregate would resample it silently)")
        }
        if abs(aggregateRate - plan.rate) > 0.5 { warnings.append("the aggregate reports \(SampleRate.format(aggregateRate)) kHz, not \(SampleRate.format(plan.rate)) kHz") }
        let corrected = rows.filter(\.driftCompensation).map(\.name)
        for f in fileRows where f.claimsBitPerfect && !corrected.isEmpty {
            warnings.append("the engine calls \(f.file) bit-perfect while \(corrected.joined(separator: ", ")) is drift-corrected (resampled): that badge would be untrue")
        }
        for f in fileRows where f.played && (f.appliedStreams ?? 0) != devices.count {
            warnings.append("\(f.file): the engine sees \(f.appliedStreams ?? 0) streams, the group has \(devices.count) members")
        }
        if let f = fileRows.first, !f.played { warnings.append("\(f.file) never started: \(f.error ?? f.state)") }

        // Teardown, then read the members again.
        teardown()
        let uid = created.uid
        aggregate = nil
        for (i, device) in devices.enumerated() {
            ProbeHAL.setNominalRate(found[i], on: device.id)
            rows[i].rateAfter = ProbeHAL.nominalRate(device.id)
            rows[i].hogPIDAfter = ProbeHAL.hogOwner(device.id)
        }
        let restored = zip(rows, found).allSatisfy { abs($0.rateAfter - $1) < 0.5 } && rows.allSatisfy { $0.hogPIDAfter != getpid() }
        return GroupPlayReport(aggregateUID: uid, aggregateStreams: aggregateStreams, aggregateRateDuringPlay: aggregateRate, rate: plan.rate,
                               rateIsSourceRate: plan.exact, members: rows, files: fileRows, truthWarnings: warnings,
                               aggregateGoneAfter: ProbeHAL.deviceID(uid: uid) == nil, restoredAllRates: restored)
    }
}

extension GroupPlayReport {
    public var text: String {
        var lines = ["group-play report — aggregate \(aggregateUID): \(aggregateStreams) streams, \(SampleRate.format(aggregateRateDuringPlay)) kHz",
                     "rate \(SampleRate.format(rate)) kHz (\(rateIsSourceRate ? "the source's own" : "NOT the source's: the engine would resample"))"]
        for m in members {
            lines.append("  \(m.name): channels \(m.firstChannel)–\(m.firstChannel + m.channels - 1) · member reads \(SampleRate.format(m.rateDuringPlay))k \(m.physicalFormatDuringPlay) · hog \(m.hogPIDDuringPlay == -1 ? "none" : m.hogPIDDuringPlay == getpid() ? "us" : String(m.hogPIDDuringPlay)) · drift correction \(m.driftCompensation ? "ON (q \(m.driftQuality))" : "off") · after: \(SampleRate.format(m.rateAfter))k (found \(SampleRate.format(m.rateFound))k)")
        }
        for f in files {
            lines.append("  \(f.file): \(f.sourceChannels) ch @ \(SampleRate.format(f.sourceRate))k · \(f.played ? "played" : "DID NOT PLAY (\(f.error ?? f.state))") · \(f.statusLine ?? "-") · channels \(f.channelNames.joined(separator: " ")) · underruns \(f.underruns)")
        }
        lines.append(contentsOf: truthWarnings.map { "TRUTH WARNING: \($0)" })
        lines.append("after: aggregate \(aggregateGoneAfter ? "gone" : "STILL LISTED"), rates and exclusive access \(restoredAllRates ? "restored" : "NOT fully restored")")
        return lines.joined(separator: "\n")
    }
}
